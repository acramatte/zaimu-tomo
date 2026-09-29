defmodule ZaimuTomo.DocumentProcessing.Worker do
  @moduledoc """
  The OCR -> extraction -> verification pipeline for a single document.

  `run/1` executes one attempt and returns `{:ok, content} | {:error, reason}`.
  It persists a SUCCESS row itself but never persists a failure: the durable
  `ZaimuTomo.DocumentProcessing.OCRJob` decides whether and when to record a
  failure based on `ZaimuTomo.DocumentProcessing.ErrorClassification` and the
  attempt number, so retries never multiply failed rows.

  Every terminal write (success and failure rows) is serialized per document:
  inside its transaction it locks the document row and re-checks the latest
  extraction against the expected id from enqueue time, so overlapping
  executions cannot append two terminal rows. A changed document rolls back
  with `:already_processed`; a deleted one with `:document_deleted`.
  """

  alias ZaimuTomo.DocumentProcessing.DocumentOCR
  alias ZaimuTomo.DocumentProcessing.ExtractedContentContext
  alias ZaimuTomo.DocumentProcessing.TemporaryFile
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Langfuse
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review
  alias ZaimuTomo.Storage
  import Ecto.Query, only: [from: 2]
  require Logger

  @doc """
  Runs one processing attempt for a self-contained command:

      %{document: %Document{}, currency_hint: String.t(), supersedes_extraction_id: id | nil}

  Returns `{:ok, %ExtractedContent{}}` when a success row was persisted,
  `{:error, :already_processed | :document_deleted}` when the terminal write
  was superseded or the document is gone, or `{:error, reason}` without
  persisting anything so the caller can retry or record a single failure.
  """
  def run(%{
        document: %{object_key: object_key} = document,
        currency_hint: currency_hint,
        supersedes_extraction_id: expected_extraction_id
      }) do
    Langfuse.trace_document_processing(document, fn ->
      trace_id = Langfuse.current_trace_id()

      case TemporaryFile.create(object_key) do
        {:ok, temporary_path} ->
          try do
            with {:ok, ^temporary_path} <- Storage.get_object(object_key, temporary_path),
                 {:ok, markdown, raw_llm_response} <- DocumentOCR.process(temporary_path),
                 {:ok, extracted_data} <-
                   ZaimuTomo.LLMClient.extract_invoice(markdown, currency_hint),
                 {:ok, verification} <-
                   ZaimuTomo.LLMClient.verify_extraction(markdown, extracted_data) do
              persist_and_emit_success(
                document,
                extracted_data,
                raw_llm_response,
                verification,
                trace_id,
                currency_hint,
                expected_extraction_id
              )
            end
          after
            File.rm(temporary_path)
          end

        {:error, posix} ->
          {:error, {:scratch_unavailable, posix}}
      end
    end)
  end

  def persist_and_emit_success(
        document,
        extracted_data,
        raw_llm_response,
        verification \\ %{"status" => "not_run"},
        trace_id \\ nil,
        currency_hint \\ nil,
        expected_extraction_id \\ nil
      ) do
    analysis = %{
      "processed_at" => DateTime.utc_now(),
      "verification" => verification
    }

    extraction_params = %{
      document_id: document.id,
      user_id: document.user_id,
      extracted_data: extracted_data,
      raw_llm_response: raw_llm_response,
      analysis: analysis,
      status: "success",
      trace_id: trace_id
    }

    Repo.transaction(fn ->
      lock_and_check_latest(document.id, expected_extraction_id)

      with {:ok, content} <- ExtractedContentContext.create_extracted_content(extraction_params),
           {:ok, _review_decision} <- Review.create_initial_decision(content) do
        # The TypeSafe shadow job is inserted in this transaction so a shadow
        # run cannot be lost between commit and enqueue.
        enqueue_typesafe_shadow(content, currency_hint)
        content
      else
        {:error, changeset} -> Repo.rollback({:persistence_failed, changeset.errors})
      end
    end)
    |> case do
      {:ok, content} ->
        Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, "document_processing:success", %{
          document_id: document.id,
          extraction_id: content.id,
          user_id: document.user_id,
          status: :completed,
          data: extracted_data,
          timestamp: DateTime.utc_now()
        })

        {:ok, content}

      {:error, :already_processed} ->
        {:error, :already_processed}

      {:error, :document_deleted} ->
        {:error, :document_deleted}

      {:error, {:persistence_failed, errors}} ->
        Logger.error(
          "[OCR] Failed to persist successful extraction for document #{document.id}: #{inspect(errors)}"
        )

        {:error, {:persistence_failed, errors}}
    end
  end

  def persist_and_emit_failure(document, error, expected_extraction_id \\ nil) do
    error_details = %{
      "type" => error_type(error),
      "message" => error_message(error),
      "stack_trace" => error_stack_trace(error),
      "timestamp" => DateTime.utc_now()
    }

    # Failed extractions persist an empty extracted-data embed because invoice
    # fields are unavailable when processing does not complete.
    extraction_params = %{
      document_id: document.id,
      user_id: document.user_id,
      # Empty map - will fail validation as expected
      extracted_data: %{},
      analysis: %{
        "error" => "Extraction failed",
        "attempted_at" => DateTime.utc_now()
      },
      status: "failed",
      error_details: error_details
    }

    Repo.transaction(fn ->
      lock_and_check_latest(document.id, expected_extraction_id)

      with {:ok, content} <- ExtractedContentContext.create_extracted_content(extraction_params),
           {:ok, _review_decision} <- Review.create_failed_decision(content, error) do
        content
      else
        {:error, changeset} -> Repo.rollback({:persistence_failed, changeset.errors})
      end
    end)
    |> case do
      {:ok, content} ->
        Phoenix.PubSub.broadcast(ZaimuTomo.PubSub, "document_processing:failed", %{
          document_id: document.id,
          extraction_id: content.id,
          user_id: document.user_id,
          status: :failed,
          error: error,
          timestamp: DateTime.utc_now()
        })

        {:ok, content}

      {:error, :already_processed} ->
        {:error, :already_processed}

      {:error, :document_deleted} ->
        {:error, :document_deleted}

      {:error, {:persistence_failed, errors}} ->
        Logger.error(
          "[OCR] Failed to persist failed extraction for document #{document.id}: #{inspect(errors)}"
        )

        {:error, {:persistence_failed, errors}}
    end
  end

  # Serialize one document's terminal write: lock the document row, then
  # re-check the latest extraction against the expected id from enqueue time.
  # An overlapping run that already appended a row rolls the transaction back
  # with :already_processed; a deleted document with :document_deleted.
  defp lock_and_check_latest(document_id, expected_extraction_id) do
    case Repo.one(from(d in Document, where: d.id == ^document_id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:document_deleted)

      %Document{} ->
        case ExtractedContentContext.get_latest_by_document(document_id) do
          nil when is_nil(expected_extraction_id) -> :ok
          %{id: ^expected_extraction_id} -> :ok
          _newer -> Repo.rollback(:already_processed)
        end
    end
  end

  # TypeSafe shadow runs are best-effort: a failed enqueue is recorded on the
  # row but never rolls back the invoice extraction.
  defp enqueue_typesafe_shadow(_content, nil), do: :ok

  defp enqueue_typesafe_shadow(content, currency_hint) when is_binary(currency_hint) do
    if ZaimuTomo.TypeSafeClient.enabled?() do
      case ZaimuTomo.TypeSafeVerification.enqueue(%{
             extracted_content_id: content.id,
             currency_hint: currency_hint
           }) do
        {:ok, _job} ->
          :ok

        {:error, _changeset} ->
          Logger.warning("[TypeSafe] Shadow verification enqueue failed class=enqueue_failed",
            typesafe_error_class: "enqueue_failed"
          )

          _result =
            ExtractedContentContext.put_typesafe_shadow(content.id, %{
              "status" => "verification_failed",
              "error" => "enqueue_failed"
            })

          :ok
      end
    else
      Logger.debug("[TypeSafe] Shadow verification skipped")
    end
  end

  # Error handling helper functions
  defp error_type(error) when is_tuple(error),
    do: elem(error, 0) |> to_string()

  defp error_type(error) when is_atom(error),
    do: Atom.to_string(error)

  defp error_type(_error),
    do: "unknown"

  defp error_message({_tag, %{reason: reason}}) when is_binary(reason), do: reason

  defp error_message(error) when is_tuple(error) do
    val = elem(error, 1)
    if is_binary(val), do: val, else: inspect(val)
  end

  defp error_message(error) when is_atom(error), do: Atom.to_string(error)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)

  defp error_stack_trace(_error),
    do: []
end
