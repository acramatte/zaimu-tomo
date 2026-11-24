defmodule ZaimuTomo.TypeSafeVerification do
  @moduledoc """
  Enqueues TypeSafe shadow-verification jobs on the durable Oban `:typesafe`
  queue.

  Job args are a self-contained command: `extracted_content_id`, the
  `currency_hint` snapshot and an optional W3C `traceparent` string linking the
  job to the caller's trace. OCR markdown and extracted data are never carried
  in `oban_jobs` (private financial text): the job re-derives them from the
  persisted row.
  """

  alias ZaimuTomo.Langfuse
  alias ZaimuTomo.TypeSafeVerification.Worker

  @spec enqueue(%{extracted_content_id: pos_integer(), currency_hint: String.t()}) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(%{extracted_content_id: extracted_content_id, currency_hint: currency_hint}) do
    %{extracted_content_id: extracted_content_id, currency_hint: currency_hint}
    |> Map.put(:traceparent, Langfuse.traceparent())
    |> Worker.new()
    |> Oban.insert()
  end
end
