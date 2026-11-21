defmodule ZaimuTomo.Statements do
  @moduledoc """
  Bank and credit card statements, uploaded against one financial account and
  read into lines by `ZaimuTomo.Statements.ExtractJob`.

  Nothing outside this context writes `statements` or `statement_lines`. The
  extraction facts have one writer, the job. A statement's status is derived,
  never stored, by `status/2`. Which journal entry backs a line is derived
  too, on every read, by `reconcile/2`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Multi
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.DocumentProcessing.ErrorClassification
  alias ZaimuTomo.FinancialAccounts.FinancialAccount
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Statements.{ExtractJob, Matcher, Reconciliation, Statement, StatementLine}
  alias ZaimuTomo.Storage

  @live_job_states ~w(available scheduled executing retryable)
  @extract_job_worker inspect(ExtractJob)

  @type status :: :processing | :ready | :failed | :stalled
  @type balance :: :balanced | {:off_by, integer()}
  @type entry :: %{statement: Statement.t(), status: status()}

  @doc """
  Stores an uploaded statement file and inserts the statement with its
  extraction job in one transaction.

  The account must belong to the scope's user. When the user already uploaded
  the same bytes, the new object is deleted and the earlier statement is
  returned as `{:error, {:already_uploaded, statement}}`.
  """
  @spec upload_statement(Scope.t(), integer() | String.t(), Path.t(), String.t()) ::
          {:ok, Statement.t()}
          | {:error, {:already_uploaded, Statement.t()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def upload_statement(%Scope{} = scope, account_id, path, filename) do
    with {:ok, account} <- fetch_account(scope, account_id),
         {:ok, stored} <- Storage.store_upload(path, filename, "statements") do
      changeset =
        %Statement{user_id: scope.user.id}
        |> Statement.upload_changeset(Map.put(stored, :financial_account_id, account.id))

      Multi.new()
      |> Multi.insert(:statement, changeset)
      |> Oban.insert(:job, fn %{statement: statement} -> ExtractJob.new_for(statement) end)
      |> Repo.transaction()
      |> case do
        {:ok, %{statement: statement}} ->
          broadcast_updated(statement)
          {:ok, statement}

        {:error, :statement, changeset, _changes} ->
          _ = Storage.delete_object(stored.object_key)
          already_uploaded_or(scope, stored.content_sha256, changeset)

        {:error, _operation, reason, _changes} ->
          _ = Storage.delete_object(stored.object_key)
          {:error, reason}
      end
    end
  end

  defp fetch_account(scope, account_id) do
    with {:ok, id} when is_integer(id) <- Ecto.Type.cast(:id, account_id),
         %FinancialAccount{} = account <-
           Repo.get_by(FinancialAccount, id: id, user_id: scope.user.id) do
      {:ok, account}
    else
      _missing ->
        {:error,
         %Statement{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:financial_account_id, "does not exist")
         |> Map.put(:action, :insert)}
    end
  end

  defp already_uploaded_or(scope, content_sha256, changeset) do
    if duplicate_file?(changeset) do
      {:error,
       {:already_uploaded,
        Repo.get_by!(Statement, user_id: scope.user.id, content_sha256: content_sha256)}}
    else
      {:error, changeset}
    end
  end

  defp duplicate_file?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique and
        opts[:constraint_name] == "statements_user_id_content_sha256_index"
    end)
  end

  @doc """
  Lists the scope's statements with their status, by account name, then
  newest period first. A statement not read yet sorts first in its account.
  """
  @spec list_statements(Scope.t()) :: [entry()]
  def list_statements(%Scope{} = scope) do
    statements =
      from(s in Statement,
        join: a in assoc(s, :financial_account),
        where: s.user_id == ^scope.user.id,
        order_by: [
          asc: a.name,
          asc: a.id,
          desc_nulls_first: s.period_end,
          desc: s.inserted_at,
          desc: s.id
        ],
        preload: [financial_account: a]
      )
      |> Repo.all()

    live_ids = live_statement_ids(Enum.map(statements, & &1.id))

    Enum.map(statements, fn statement ->
      %{statement: statement, status: status(statement, statement.id in live_ids)}
    end)
  end

  @doc """
  Checks the scope's statements with these ids against the journal and
  returns `%{id => Reconciliation.t()}`. An id that is missing or another
  user's is left out.

  The only read of matches, computed on every call and never stored. Only
  posted journal entries of the scope's user back lines. The lines of every
  statement of the user that share an amount group with the requested lines
  are matched together, so one entry never backs two lines on two statements.
  """
  @spec reconcile(Scope.t(), [integer()]) :: %{integer() => Reconciliation.t()}
  def reconcile(%Scope{} = scope, ids) do
    statements =
      from(s in Statement,
        where: s.user_id == ^scope.user.id and s.id in ^ids,
        preload: [:financial_account, :lines]
      )
      |> Repo.all()

    live_ids = statements |> Enum.map(& &1.id) |> live_statement_ids()
    matches = matches(scope, Enum.flat_map(statements, & &1.lines))

    Map.new(statements, fn statement ->
      status = status(statement, statement.id in live_ids)
      {statement.id, Reconciliation.new(statement, status, balance(statement), matches)}
    end)
  end

  @doc """
  Reconciles one of the scope's statements, as `reconcile/2` does. Raises
  `Ecto.NoResultsError` for a missing or foreign id.
  """
  @spec get_reconciliation!(Scope.t(), term()) :: Reconciliation.t()
  def get_reconciliation!(%Scope{} = scope, id),
    do: get_reconciliation(scope, id) || raise(Ecto.NoResultsError, queryable: Statement)

  @doc """
  Reconciles one of the scope's statements, as `reconcile/2` does, or returns
  `nil` for a missing or foreign id, such as a statement deleted while a page
  shows it.
  """
  @spec get_reconciliation(Scope.t(), term()) :: Reconciliation.t() | nil
  def get_reconciliation(%Scope{} = scope, id) do
    with {:ok, id} <- Ecto.Type.cast(:id, id),
         %{^id => reconciliation} <- reconcile(scope, [id]) do
      reconciliation
    else
      _missing -> nil
    end
  end

  # `Matcher.match/2` answers each amount group on its own, so matching the
  # groups of `lines` whole gives every line the answer a run over all of the
  # user's lines would give.
  defp matches(scope, lines) do
    {group_lines, keys} = amount_groups(scope, amount_keys(lines))

    # An entry without an invoice date has no window to match in.
    entries =
      scope
      |> Accounting.list_posted_entries_for_amount_keys(MapSet.to_list(keys))
      |> Enum.reject(&is_nil(&1.date))

    entries_by_id = Map.new(entries, &{&1.id, &1})

    group_lines
    |> Enum.map(&line_in/1)
    |> Matcher.match(Enum.map(entries, &entry_in/1))
    |> Map.new(fn {line_id, {entry_id, confidence}} ->
      {line_id, {Map.fetch!(entries_by_id, entry_id), confidence}}
    end)
  end

  defp line_in(line) do
    %{
      id: line.id,
      date: line.booking_date,
      keys: Matcher.line_keys(line),
      description: line.description
    }
  end

  defp entry_in(entry),
    do: %{id: entry.id, date: entry.date, key: Matcher.entry_key(entry), issuer: entry.issuer}

  # A foreign-amount line has two keys and joins two amount groups, so load
  # the user's lines under the keys until no new key turns up.
  defp amount_groups(scope, keys) do
    lines = debit_lines_with_keys(scope, keys)
    grown = MapSet.union(keys, amount_keys(lines))

    if MapSet.equal?(grown, keys), do: {lines, keys}, else: amount_groups(scope, grown)
  end

  defp amount_keys(lines), do: lines |> Enum.flat_map(&Matcher.line_keys/1) |> MapSet.new()

  defp debit_lines_with_keys(scope, keys) do
    {cents, currencies} =
      keys |> Enum.map(fn {cents, currency} -> {-cents, currency} end) |> Enum.unzip()

    from(l in StatementLine,
      where: l.user_id == ^scope.user.id and l.amount_cents < 0,
      where:
        fragment(
          "(?, ?) IN (SELECT * FROM unnest(?::bigint[], ?::text[]))",
          l.amount_cents,
          l.currency,
          ^cents,
          ^currencies
        ) or
          fragment(
            "(?, ?) IN (SELECT * FROM unnest(?::bigint[], ?::text[]))",
            l.original_amount_cents,
            l.original_currency,
            ^cents,
            ^currencies
          )
    )
    |> Repo.all()
  end

  @doc """
  The status of a statement, as `status/2` reads it with its live job.
  """
  @spec status(Statement.t()) :: status()
  def status(%Statement{id: id} = statement),
    do: status(statement, live_statement_ids([id]) != [])

  @doc """
  The status rule, the only one. A live extraction job means `:processing`.
  Otherwise the last run's facts decide: a failure code is `:failed` (even
  over an earlier good read, whose lines stay), a read is `:ready`, and
  nothing recorded is `:stalled`.
  """
  @spec status(Statement.t(), boolean()) :: status()
  def status(_statement, true), do: :processing
  def status(%Statement{failure_code: code}, false) when is_binary(code), do: :failed
  def status(%Statement{extracted_at: %DateTime{}}, false), do: :ready
  def status(%Statement{}, false), do: :stalled

  @doc """
  Whether a read statement's lines add up: `opening + sum(lines) - closing`.
  Zero is `:balanced`. Returns nil for a statement not read yet. Needs the
  lines loaded.
  """
  @spec balance(Statement.t()) :: balance() | nil
  def balance(%Statement{extracted_at: nil}), do: nil

  def balance(%Statement{lines: lines} = statement) when is_list(lines) do
    case statement.opening_balance_cents + Enum.sum_by(lines, & &1.amount_cents) -
           statement.closing_balance_cents do
      0 -> :balanced
      gap -> {:off_by, gap}
    end
  end

  @doc """
  Enqueues a new extraction for a statement that is failed, stalled, or read
  but unbalanced. It only enqueues: the job writes the result.
  """
  @spec retry_extraction(Scope.t(), Statement.t()) ::
          {:ok, Statement.t()} | {:error, :not_found | :not_retryable}
  def retry_extraction(%Scope{} = scope, %Statement{id: id}) do
    Repo.transact(fn ->
      with %Statement{} = statement <- locked_statement(scope, id),
           statement = Repo.preload(statement, :lines),
           true <-
             retryable?(status(statement, live_statement_ids([id]) != []), balance(statement)),
           {:ok, _job} <- statement |> ExtractJob.new_for() |> Oban.insert() do
        {:ok, statement}
      else
        nil -> {:error, :not_found}
        false -> {:error, :not_retryable}
        {:error, %Ecto.Changeset{}} -> {:error, :not_retryable}
      end
    end)
    |> case do
      {:ok, statement} ->
        broadcast_updated(statement)
        {:ok, statement}

      error ->
        error
    end
  end

  @doc """
  Whether a statement with this status and balance may be read again: a
  failed or stalled one, or a read one whose lines do not add up.
  """
  @spec retryable?(status(), balance() | nil) :: boolean()
  def retryable?(status, _balance) when status in [:failed, :stalled], do: true
  def retryable?(:ready, {:off_by, _gap}), do: true
  def retryable?(_status, _balance), do: false

  @failures %{
    "currency_mismatch" => "its currency is not the account's currency",
    "account_mismatch" => "it names another account than this one",
    "inconsistent_header" => "two pages print a different period, currency, or account",
    "missing_header" => "the period, currency, or a balance could not be found",
    "no_lines" => "no lines were found although the balance moved",
    "line_outside_period" => "a line is dated months away from the statement's period",
    "duplicate_period" => "this account already has a statement for this period"
  }

  @doc """
  Describes a statement's `failure_code` as a short phrase for the user.

  The ways a read can fail to fit its account (`ParsedStatement`'s refusals
  and `duplicate_period`) are worded here; every other code is a processing
  failure and is worded by `ErrorClassification.describe/1`.
  """
  @spec describe_failure(String.t()) :: String.t()
  def describe_failure(code),
    do: Map.get_lazy(@failures, code, fn -> ErrorClassification.describe(code) end)

  @doc """
  Deletes a statement and its lines, then its stored file.
  """
  @spec delete_statement(Scope.t(), Statement.t()) ::
          {:ok, Statement.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_statement(%Scope{} = scope, %Statement{id: id}) do
    with %Statement{} = statement <- Repo.get_by(Statement, id: id, user_id: scope.user.id),
         {:ok, deleted} <- Repo.delete(statement) do
      case Storage.delete_object(deleted.object_key) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Statements] Could not delete the file of statement #{deleted.id}: #{inspect(reason)}"
          )
      end

      Phoenix.PubSub.broadcast(
        ZaimuTomo.PubSub,
        topic(deleted.user_id),
        {:statement_deleted, deleted.id}
      )

      {:ok, deleted}
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Subscribes to the scope's statement events: `{:statement_updated, id}` after
  an upload, a retry, or an extraction result, and `{:statement_deleted, id}`.
  """
  @spec subscribe(Scope.t()) :: :ok | {:error, term()}
  def subscribe(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(ZaimuTomo.PubSub, topic(scope.user.id))
  end

  @doc false
  def broadcast_updated(%Statement{id: id, user_id: user_id}) do
    Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, topic(user_id), {:statement_updated, id})
  end

  defp topic(user_id), do: "user:#{user_id}:statements"

  defp locked_statement(scope, id) do
    Repo.one(
      from s in Statement,
        where: s.id == ^id and s.user_id == ^scope.user.id,
        lock: "FOR UPDATE"
    )
  end

  defp live_statement_ids([]), do: []

  defp live_statement_ids(ids) do
    from(j in Oban.Job,
      where: j.worker == @extract_job_worker and j.state in @live_job_states,
      where: fragment("?->>'statement_id'", j.args) in ^Enum.map(ids, &to_string/1),
      select: fragment("?->>'statement_id'", j.args)
    )
    |> Repo.all()
    |> Enum.map(&String.to_integer/1)
  end
end
