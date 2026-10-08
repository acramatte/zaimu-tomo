defmodule ZaimuTomo.DocumentProcessing do
  @moduledoc """
  The DocumentProcessing context.

  Builds durable OCR job commands that Oban dispatches. The enqueue is atomic
  with the document insert (see `ZaimuTomo.Documents.create_document/2`), so an
  upload can never exist without its processing job.
  """

  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.Documents.Document

  @doc """
  Builds the OCR job changeset for a document.

  The command is self-contained and resolved at enqueue time: the document id,
  a queue-time snapshot of the owner's base currency (`currency_hint`), and the
  latest extraction id to supersede (or `nil` when there is none). The worker
  pattern-matches this command and never queries Accounts.
  """
  def ocr_job(%Document{} = document, currency_hint, supersedes_extraction_id) do
    OCRJob.new(%{
      document_id: document.id,
      currency_hint: currency_hint,
      supersedes_extraction_id: supersedes_extraction_id
    })
  end
end
