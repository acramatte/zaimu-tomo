defmodule ZaimuTomo.DocumentProcessing.Recovery do
  @moduledoc """
  Unscoped maintenance recovery for stuck documents: no extraction row and no
  live OCR job (e.g. a run that was lost to a crash or a discarded job).

  Grouped per user so each run uses the owner's own base currency snapshot,
  mirroring the enqueue-time snapshot semantics of `DocumentProcessing.ocr_job/3`.
  """

  import Ecto.Query

  alias ZaimuTomo.Accounts.User
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  @type group :: %{user_id: pos_integer(), currency: String.t(), document_ids: [pos_integer()]}

  @doc """
  Lists stuck documents (no extraction row, no live OCR job), grouped per user
  with that user's base currency.

  Intentionally unscoped: maintenance commands operate on the complete document
  collection (like `ZaimuTomo.Documents.list_document_object_keys/0`).
  """
  @spec list_stuck() :: [group()]
  def list_stuck do
    # Correlated NOT EXISTS with a safe text comparison: a malformed live job
    # (missing or non-numeric document_id) neither hides every document (as a
    # NULL-poisoned NOT IN would) nor raises (as a ::bigint cast would).
    from(d in Document,
      as: :doc,
      join: u in User,
      on: u.id == d.user_id,
      left_join: ec in ExtractedContent,
      on: ec.document_id == d.id,
      where: is_nil(ec.id),
      where:
        not exists(
          from(j in DocumentProcessing.live_jobs(),
            where: fragment("?->>'document_id' = ?::text", j.args, parent_as(:doc).id),
            select: 1
          )
        ),
      order_by: [asc: u.id, asc: d.id],
      select: %{user_id: u.id, currency: u.base_currency, document_id: d.id}
    )
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
    |> Enum.sort_by(fn {user_id, _rows} -> user_id end)
    |> Enum.map(fn {user_id, rows} ->
      %{
        user_id: user_id,
        currency: hd(rows).currency,
        document_ids: Enum.map(rows, & &1.document_id)
      }
    end)
  end

  @doc """
  Enqueues one fresh OCR job per stuck document and returns the enqueued jobs.

  Idempotent through OCRJob uniqueness: when a live job already exists for a
  document, Oban reports a conflict and no second job is created.
  """
  @spec enqueue_stuck([group()]) :: [Oban.Job.t()]
  def enqueue_stuck(groups) when is_list(groups) do
    Enum.flat_map(groups, fn %{currency: currency, document_ids: document_ids} ->
      Enum.flat_map(document_ids, fn document_id ->
        %Document{id: document_id}
        |> DocumentProcessing.ocr_job(currency, nil)
        |> Oban.insert()
        |> case do
          {:ok, %Oban.Job{conflict?: true}} -> []
          {:ok, %Oban.Job{} = job} -> [job]
        end
      end)
    end)
  end
end
