defmodule ZaimuTomo.Activity do
  @moduledoc """
  User-scoped activity assembled from document-processing and posting records.

  Each item represents the document's current place in the workflow, using the
  document list's rule (`Review.document_status/2`): the OCR job queue decides
  between processing, stalled, and failed, and a completed extraction's review
  state then decides between review, posted, and rejected.
  """

  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.Documents
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Review

  @doc """
  Lists the newest activity for the scope, ordered by the latest user-visible
  workflow transition.
  """
  def list_recent(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    documents = Documents.list_documents(scope)
    states = DocumentProcessing.processing_states(Enum.map(documents, & &1.id))

    documents
    |> Enum.map(&to_activity_item(&1, states[&1.id]))
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
    |> maybe_take(limit)
  end

  defp maybe_take(items, :all), do: items
  defp maybe_take(items, limit), do: Enum.take(items, limit)

  defp to_activity_item(%Document{} = document, state) do
    content = List.first(document.extracted_content)
    decision = content && content.review_decision
    data = effective_activity_data(content, decision)

    %{
      id: activity_id(document, content, decision),
      status: Review.document_status(state, content),
      merchant: data && data.issuer,
      filename: document.filename,
      amount_cents: data && data.amount_to_pay_cents,
      currency: data && data.currency,
      invoice_no: data && data.invoice_number,
      error: activity_error(content, decision),
      occurred_at: activity_timestamp(document, content, decision),
      document_id: document.id
    }
  end

  defp effective_activity_data(_content, %{decision_data: data}) when not is_nil(data),
    do: data

  defp effective_activity_data(_content, %{original_data: data}) when not is_nil(data),
    do: data

  defp effective_activity_data(%{extracted_data: data}, _decision) when not is_nil(data),
    do: data

  defp effective_activity_data(_content, _decision), do: nil

  defp activity_error(%{error_details: error_details}, _decision) when is_map(error_details) do
    Map.get(error_details, "message") || Map.get(error_details, :message) || "Processing failed"
  end

  defp activity_error(_content, %{rejection_reason: reason}) when is_binary(reason), do: reason
  defp activity_error(_content, _decision), do: nil

  defp activity_timestamp(document, content, decision) do
    timestamp =
      cond do
        decision && decision.review_completed_at -> decision.review_completed_at
        content -> content.updated_at
        true -> document.updated_at
      end

    as_utc_datetime(timestamp)
  end

  defp as_utc_datetime(%DateTime{} = timestamp), do: timestamp

  defp as_utc_datetime(%NaiveDateTime{} = timestamp) do
    DateTime.from_naive!(timestamp, "Etc/UTC")
  end

  defp activity_id(_document, _content, %{id: id}), do: "review-#{id}"
  defp activity_id(_document, %{id: id}, _decision), do: "extraction-#{id}"
  defp activity_id(%{id: id}, _content, _decision), do: "document-#{id}"
end
