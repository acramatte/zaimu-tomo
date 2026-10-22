defmodule ZaimuTomo.DocumentProcessingTest do
  use ZaimuTomo.DataCase, async: false

  import ZaimuTomo.ReviewFixtures,
    only: [extracted_content_fixture: 2, extracted_content_fixture: 3]

  alias ZaimuTomo.AccountsFixtures
  alias ZaimuTomo.DocumentProcessing
  alias ZaimuTomo.DocumentProcessing.DocumentOCR
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  describe "ocr_job/3" do
    test "builds a self-contained command snapshotting the currency at enqueue time" do
      scope = AccountsFixtures.user_scope_fixture()

      document =
        %Document{}
        |> Document.changeset(%{filename: "a.pdf", object_key: "documents/a.pdf"}, scope)
        |> Repo.insert!()

      changeset = DocumentProcessing.ocr_job(document, "CHF", 42)
      assert %Ecto.Changeset{valid?: true} = changeset

      args = Ecto.Changeset.get_field(changeset, :args)
      assert args[:document_id] == document.id
      assert args[:currency_hint] == "CHF"
      assert args[:supersedes_extraction_id] == 42
    end

    test "uses the documents queue" do
      scope = AccountsFixtures.user_scope_fixture()

      document =
        %Document{}
        |> Document.changeset(%{filename: "a.pdf", object_key: "documents/a.pdf"}, scope)
        |> Repo.insert!()

      changeset = DocumentProcessing.ocr_job(document, "CHF", nil)
      assert Ecto.Changeset.get_field(changeset, :queue) == "documents"
    end
  end

  describe "processing_states/1" do
    setup do
      scope = AccountsFixtures.user_scope_fixture()
      %{scope: scope, user: scope.user}
    end

    defp insert_document(scope, name) do
      %Document{}
      |> Document.changeset(%{filename: name, object_key: "documents/#{name}"}, scope)
      |> Repo.insert!()
    end

    defp count_queries(fun) do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        ref,
        [:zaimu_tomo, :repo, :query],
        fn _event, _measure, _meta, _ -> send(test_pid, {ref, :query}) end,
        nil
      )

      result = fun.()
      :telemetry.detach(ref)
      {result, length(Stream.repeatedly(fn -> receive_query(ref) end) |> Enum.take_while(& &1))}
    end

    defp receive_query(ref) do
      receive do
        {^ref, :query} -> true
      after
        0 -> false
      end
    end

    test "classifies each durable state like processing_state/1", %{scope: scope, user: user} do
      live = insert_document(scope, "live.pdf")
      DocumentProcessing.ocr_job(live, "CHF", nil) |> Oban.insert!()

      stuck = insert_document(scope, "stuck.pdf")

      failed = insert_document(scope, "failed.pdf")
      extracted_content_fixture(failed, user, %{status: "failed"})

      rerun = insert_document(scope, "rerun.pdf")
      extracted_content_fixture(rerun, user, %{status: "failed"})
      DocumentProcessing.ocr_job(rerun, "CHF", nil) |> Oban.insert!()

      extracted = insert_document(scope, "extracted.pdf")
      extracted_content_fixture(extracted, user, %{status: "failed"})
      extracted_content_fixture(extracted, user)

      docs = [live, stuck, failed, rerun, extracted]
      states = DocumentProcessing.processing_states(Enum.map(docs, & &1.id))

      assert states == %{
               live.id => :processing,
               stuck.id => :stuck,
               failed.id => :failed,
               rerun.id => :processing,
               extracted.id => :extracted
             }

      for doc <- docs, do: assert(states[doc.id] == DocumentProcessing.processing_state(doc))
    end

    test "uses a bounded number of queries regardless of document count", %{scope: scope} do
      few = for n <- 1..2, do: insert_document(scope, "few#{n}.pdf")
      many = few ++ for n <- 1..20, do: insert_document(scope, "many#{n}.pdf")

      {_, few_queries} = count_queries(fn -> DocumentProcessing.processing_states(ids(few)) end)
      {_, many_queries} = count_queries(fn -> DocumentProcessing.processing_states(ids(many)) end)

      assert few_queries == 2
      assert many_queries == few_queries
    end

    defp ids(docs), do: Enum.map(docs, & &1.id)
  end

  describe "DocumentOCR processing" do
    test "DocumentOCR.process/1 handles file processing" do
      # Test with a non-existent file (should return error)
      result = DocumentOCR.process("non_existent_file.pdf")

      # Should return an error tuple
      assert match?({:error, _}, result)
    end
  end
end
