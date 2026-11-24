defmodule ZaimuTomo.Statements.ExtractJob do
  @moduledoc """
  Reads one uploaded statement into its header and lines.

  The only arg is `statement_id`. One attempt downloads the file, OCRs it,
  reads each page with the extractor (one call per page, in order), and merges
  the pages with `ParsedStatement.from_pages/2`.

  `persist/2` is the only writer of `extracted_at`, the header, the lines, and
  `failure_code`. It locks the statement row, so a retry or a delete waits for
  it. A success replaces the lines wholesale and clears `failure_code`, so a
  rerun converges on the same rows. A failure sets `failure_code` and keeps
  the last good read. A transient error on a non-final attempt persists
  nothing and returns `{:error, ErrorClassification.summarize(reason)}`, so
  Oban retries with a body-free reason. A deleted statement cancels the job.
  """
  @live_states [:available, :scheduled, :executing, :retryable]

  use Oban.Worker,
    queue: :statements,
    max_attempts: 5,
    unique: [
      keys: [:statement_id],
      states: @live_states,
      period: :infinity
    ]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias ZaimuTomo.DocumentProcessing.{DocumentOCR, ErrorClassification, TemporaryFile}
  alias ZaimuTomo.LLMClient
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Statements
  alias ZaimuTomo.Statements.{ParsedStatement, Statement, StatementLine}
  alias ZaimuTomo.Storage

  @doc "Oban job states considered live for statement extraction."
  @spec live_states() :: [atom()]
  def live_states, do: @live_states

  @doc "String names of `live_states/0`, for Ecto queries on `oban_jobs.state`."
  @spec live_state_names() :: [String.t()]
  def live_state_names, do: Enum.map(@live_states, &Atom.to_string/1)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @doc """
  Builds the job for a statement, with the partial unique index that allows
  one live job per statement declared as a constraint.
  """
  @spec new_for(Statement.t()) :: Ecto.Changeset.t()
  def new_for(%Statement{id: id}) do
    %{statement_id: id}
    |> new()
    |> Ecto.Changeset.unique_constraint(:args,
      name: :oban_jobs_one_live_extract_job_per_statement
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"statement_id" => id}} = job) do
    with {:ok, statement} <- fetch(id),
         {:ok, pages} <- read_pages(statement),
         {:ok, parsed} <- parse(pages, statement) do
      persist(id, {:ok, parsed})
    else
      {:cancel, _reason} = cancel -> cancel
      {:failed, code} -> persist(id, {:error, code})
      {:error, reason} -> settle_error(id, reason, job)
    end
  end

  defp fetch(id) do
    case Repo.get(Statement, id) |> Repo.preload(:financial_account) do
      %Statement{} = statement -> {:ok, statement}
      nil -> {:cancel, :statement_deleted}
    end
  end

  defp read_pages(%Statement{object_key: object_key} = statement) do
    case TemporaryFile.create(object_key) do
      {:ok, path} ->
        try do
          with {:ok, ^path} <- Storage.get_object(object_key, path),
               {:ok, _markdown, body} <- DocumentOCR.process(path) do
            body |> DocumentOCR.page_markdowns() |> extract_pages(statement.financial_account)
          end
        after
          File.rm(path)
        end

      {:error, posix} ->
        {:error, {:scratch_unavailable, posix}}
    end
  end

  defp extract_pages(markdowns, account) do
    count = length(markdowns)

    markdowns
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {markdown, number}, {:ok, pages} ->
      context = %{
        page: number,
        pages: count,
        account_type: account.account_type,
        currency: account.currency,
        period: pages |> Enum.reverse() |> Enum.find_value(&ParsedStatement.page_period/1)
      }

      case LLMClient.extract_statement_page(markdown, context) do
        {:ok, page} -> {:cont, {:ok, [page | pages]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, Enum.reverse(pages)}
      error -> error
    end
  end

  defp parse(pages, statement) do
    case ParsedStatement.from_pages(pages, statement.financial_account) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, failure} -> {:failed, Atom.to_string(failure)}
    end
  end

  defp settle_error(id, reason, job) do
    case {ErrorClassification.classify(reason), final_attempt?(job)} do
      {:transient, false} ->
        {:error, ErrorClassification.summarize(reason)}

      {class, _final?} ->
        code = ErrorClassification.summarize(reason)
        Logger.warning("[Statements] Extraction failed for statement #{id} (#{class}): #{code}")
        persist(id, {:error, code})
    end
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt >= max

  defp persist(id, result) do
    Repo.transact(fn ->
      case Repo.one(from s in Statement, where: s.id == ^id, lock: "FOR UPDATE") do
        nil -> {:error, :statement_deleted}
        statement -> write(statement, result)
      end
    end)
    |> case do
      {:ok, statement} ->
        Statements.broadcast_updated(statement)
        :ok

      {:error, :statement_deleted} ->
        {:cancel, :statement_deleted}

      {:error, :duplicate_period} ->
        persist(id, {:error, "duplicate_period"})

      {:error, {:persistence_failed, _errors}} ->
        persist(id, {:error, "persistence_failed"})
    end
  end

  defp write(statement, {:error, code}) do
    statement |> Ecto.Changeset.change(failure_code: code) |> Repo.update()
  end

  defp write(statement, {:ok, %ParsedStatement{} = parsed}) do
    Repo.delete_all(from l in StatementLine, where: l.statement_id == ^statement.id)

    statement
    |> Ecto.Changeset.change(
      extracted_at: DateTime.utc_now(:second),
      account_ref: parsed.account_ref,
      period_start: parsed.period_start,
      period_end: parsed.period_end,
      currency: parsed.currency,
      opening_balance_cents: parsed.opening_cents,
      closing_balance_cents: parsed.closing_cents,
      failure_code: nil
    )
    |> Ecto.Changeset.unique_constraint([:financial_account_id, :period_start, :period_end],
      name: :statements_one_per_account_period
    )
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Repo.insert_all(StatementLine, line_rows(updated, parsed))
        {:ok, updated}

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_update_error(statement.id, changeset)
    end
  end

  defp handle_update_error(statement_id, changeset) do
    if duplicate_period?(changeset) do
      {:error, :duplicate_period}
    else
      keys = changeset.errors |> Keyword.keys() |> Enum.uniq() |> Enum.sort()

      Logger.warning(
        "[Statements] Could not persist extraction for statement #{statement_id}: #{inspect(keys)}"
      )

      {:error, {:persistence_failed, changeset.errors}}
    end
  end

  defp duplicate_period?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique and
        opts[:constraint_name] == "statements_one_per_account_period"
    end)
  end

  defp line_rows(statement, parsed) do
    parsed.lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, position} ->
      {original_amount_cents, original_currency} = line.original || {nil, nil}

      %{
        statement_id: statement.id,
        user_id: statement.user_id,
        position: position,
        booking_date: line.booking_date,
        value_date: line.value_date,
        description: line.description,
        amount_cents: line.amount_cents,
        currency: parsed.currency,
        original_amount_cents: original_amount_cents,
        original_currency: original_currency
      }
    end)
  end
end
