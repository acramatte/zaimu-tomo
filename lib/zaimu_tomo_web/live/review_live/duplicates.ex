defmodule ZaimuTomoWeb.ReviewLive.Duplicates do
  @moduledoc """
  Copy shared by the review show and amend views for
  `ZaimuTomo.Accounting.duplicate_check/3` verdicts.

  An exact-file match is described as the same uploaded file, never as an
  invoice-number match, and the fingerprint itself is never rendered.
  """

  @doc "Panel heading for a verdict."
  def title(verdict) when verdict in [:same_file_blocked, :file_reuse],
    do: "Same file already recorded"

  def title(:invoice_number), do: "Invoice already recorded"
  def title(_verdict), do: "Possible duplicate"

  @doc "Flash shown when posting is refused."
  def refusal_message(:same_file_blocked),
    do:
      "This file has already been recorded with the same invoice details. Reject this duplicate review."

  def refusal_message(:file_reuse),
    do:
      "This file has already been recorded. Confirm it is a reused bill for a new period, or reject the review."

  def refusal_message(:invoice_number),
    do:
      "This invoice number has already been recorded for this issuer. Amend the data or reject the document."

  def refusal_message(_verdict),
    do: "The duplicate check changed since this page loaded. Review the matches and try again."

  @doc "Posting date of the most recent exact-file match."
  def file_match_posted_on(%{candidates: candidates}) do
    case Enum.find(candidates, &(&1.reason == :same_file)) do
      %{entry: %{inserted_at: %DateTime{} = posted_at}} ->
        Calendar.strftime(posted_at, "%Y-%m-%d")

      _ ->
        "an earlier date"
    end
  end
end
