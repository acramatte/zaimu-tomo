defmodule ZaimuTomo.Activity do
  @moduledoc """
  User-scoped activity assembled from document-processing and posting records.

  Each item represents the document's current place in the workflow. Documents
  with no extraction are shown as processing; extraction and review state then
  determines whether an item needs review, has failed, or has been posted.
  """

  alias ZaimuTomo.Accounts.Scope
  alias ZaimuTomo.Documents
  alias ZaimuTomo.Documents.Document

  @doc """
  Lists the newest activity for the scope, ordered by the latest user-visible
  workflow transition.
  """
  def list_recent(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    scope
    |> Documents.list_documents()
    |> Enum.map(&to_activity_item/1)
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
    |> maybe_take(limit)
  end

  defp maybe_take(items, :all), do: items
  defp maybe_take(items, limit), do: Enum.take(items, limit)

  defp to_activity_item(%Document{} = document) do
    content = List.first(document.extracted_content)
    decision = content && content.review_decision

    data =
      (decision && (decision.decision_data || decision.original_data)) ||
        (content && content.extracted_data)

    %{
      id: activity_id(document, content, decision),
      status: activity_status(content, decision),
      merchant: data && data.issuer,
      filename: document.filename,
      amount_cents: data && data.amount_to_pay_cents,
      currency: data && data.currency,
      invoice_no: data && data.invoice_number,
      error: activity_error(content, decision),
      occurred_at: activity_timestamp(document, content, decision),
      review_id: decision && decision.id,
      document_id: document.id
    }
  end

  defp activity_status(nil, _decision), do: "processing"
  defp activity_status(%{status: "failed"}, _decision), do: "failed"

  defp activity_status(_content, %{review_status: status}) when status in ["approved", "amended"],
    do: "posted"

  defp activity_status(_content, %{review_status: "rejected"}), do: "failed"
  defp activity_status(_content, _decision), do: "review"

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
