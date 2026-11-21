defmodule ZaimuTomo.Statements do
  @moduledoc """
  Bank and credit card statements, uploaded against one financial account and
  read into lines by `ZaimuTomo.Statements.ExtractJob`.

  Nothing outside this context writes `statements` or `statement_lines`. The
  extraction facts have one writer, the job. A statement's status is derived,
  never stored, by `status/2`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Multi
  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.DocumentProcessing.ErrorClassification
  alias ZaimuTomo.FinancialAccounts.FinancialAccount
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Statements.{ExtractJob, Statement}
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
  Gets one of the scope's statements with its account and lines. Raises
  `Ecto.NoResultsError` for a missing or foreign id.
  """
  @spec get_statement!(Scope.t(), term()) :: Statement.t()
  def get_statement!(%Scope{} = scope, id) do
    Statement
    |> Repo.get_by!(id: id, user_id: scope.user.id)
    |> Repo.preload([:financial_account, :lines])
  end

  @doc """
  Gets one of the scope's statements with its account and lines, or `nil` for
  a missing or foreign id, such as a statement deleted while a page shows it.
  """
  @spec get_statement(Scope.t(), term()) :: Statement.t() | nil
  def get_statement(%Scope{} = scope, id) do
    case Repo.get_by(Statement, id: id, user_id: scope.user.id) do
      nil -> nil
      statement -> Repo.preload(statement, [:financial_account, :lines])
    end
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
