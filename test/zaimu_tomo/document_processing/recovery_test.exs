defmodule ZaimuTomo.DocumentProcessing.RecoveryTest do
  use ZaimuTomo.DataCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  import ExUnit.CaptureIO

  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.DocumentProcessing.Recovery
  alias ZaimuTomo.Documents
  alias ZaimuTomo.Release

  import ZaimuTomo.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]
  import ZaimuTomo.DocumentsFixtures, only: [document_fixture: 2]

  import ZaimuTomo.ReviewFixtures,
    only: [extracted_content_fixture: 2, extracted_content_fixture: 3]

  setup do
    # Release.start_app/0 rewrites the Oban config (queues/plugins/peer off for
    # eval nodes); restore the test config afterwards.
    original = Application.get_env(:zaimu_tomo, Oban)
    on_exit(fn -> Application.put_env(:zaimu_tomo, Oban, original) end)
    :ok
  end

  defp user_with_currency(currency) do
    user = user_fixture()
    {:ok, user} = user |> Ecto.Changeset.change(base_currency: currency) |> Repo.update()
    user
  end

  describe "list_stuck/0" do
    test "groups stuck documents per user with each user's base currency" do
      chf_user = user_with_currency("CHF")
      eur_user = user_with_currency("EUR")
      chf_doc = document_fixture(user_scope_fixture(chf_user), %{object_key: "documents/chf.pdf"})
      eur_doc = document_fixture(user_scope_fixture(eur_user), %{object_key: "documents/eur.pdf"})

      assert [
               %{user_id: chf_id, currency: "CHF", document_ids: [chf_id_doc]},
               %{user_id: eur_id, currency: "EUR", document_ids: [eur_id_doc]}
             ] = Recovery.list_stuck()

      assert {chf_id, chf_id_doc} == {chf_user.id, chf_doc.id}
      assert {eur_id, eur_id_doc} == {eur_user.id, eur_doc.id}
    end

    test "excludes documents with a failed row, a successful row, or a live job" do
      scope = user_scope_fixture(user_fixture())
      failed_doc = document_fixture(scope, %{object_key: "documents/failed.pdf"})
      extracted_content_fixture(failed_doc, scope.user, %{status: "failed"})
      extracted_doc = document_fixture(scope, %{object_key: "documents/extracted.pdf"})
      extracted_content_fixture(extracted_doc, scope.user)

      {:ok, _live_doc} =
        Documents.create_document(scope, %{filename: "live.pdf", object_key: "documents/live.pdf"})

      stuck_doc = document_fixture(scope, %{object_key: "documents/stuck.pdf"})

      assert [%{document_ids: [stuck_id]}] = Recovery.list_stuck()
      assert stuck_id == stuck_doc.id
    end
  end

  describe "enqueue_stuck/1" do
    test "enqueues one job per stuck document with each user's currency" do
      chf_user = user_with_currency("CHF")
      eur_user = user_with_currency("EUR")
      chf_doc = document_fixture(user_scope_fixture(chf_user), %{object_key: "documents/chf.pdf"})
      eur_doc = document_fixture(user_scope_fixture(eur_user), %{object_key: "documents/eur.pdf"})

      jobs = Recovery.enqueue_stuck(Recovery.list_stuck())

      assert length(jobs) == 2

      assert_enqueued(
        worker: OCRJob,
        args: %{document_id: chf_doc.id, currency_hint: "CHF", supersedes_extraction_id: nil}
      )

      assert_enqueued(
        worker: OCRJob,
        args: %{document_id: eur_doc.id, currency_hint: "EUR", supersedes_extraction_id: nil}
      )
    end

    test "is idempotent through job uniqueness" do
      scope = user_scope_fixture(user_fixture())
      document = document_fixture(scope, %{object_key: "documents/stuck.pdf"})
      groups = Recovery.list_stuck()

      assert [_job] = Recovery.enqueue_stuck(groups)
      assert [] = Recovery.enqueue_stuck(groups)

      assert [_] = all_enqueued(worker: OCRJob, args: %{document_id: document.id})
    end
  end

  describe "Release.recover_stuck_documents!/1" do
    test "dry run prints ids per user and enqueues nothing" do
      scope = user_scope_fixture(user_fixture())
      document = document_fixture(scope, %{object_key: "documents/stuck.pdf"})

      output = capture_io(fn -> Release.recover_stuck_documents!() end)

      assert output =~ "user #{scope.user.id}"
      assert output =~ to_string(document.id)
      assert output =~ "Dry run"
      refute_enqueued(worker: OCRJob)
    end

    test "confirm enqueues one job per stuck document" do
      scope = user_scope_fixture(user_fixture())
      stuck_doc = document_fixture(scope, %{object_key: "documents/stuck.pdf"})
      failed_doc = document_fixture(scope, %{object_key: "documents/failed.pdf"})
      extracted_content_fixture(failed_doc, scope.user, %{status: "failed"})

      {:ok, _live_doc} =
        Documents.create_document(scope, %{filename: "live.pdf", object_key: "documents/live.pdf"})

      output = capture_io(fn -> Release.recover_stuck_documents!(confirm: true) end)

      assert output =~ "Enqueued 1 OCR jobs"
      # The upload's own job plus exactly one recovery job.
      assert [_] = all_enqueued(worker: OCRJob, args: %{document_id: stuck_doc.id})
      assert [_, _] = all_enqueued(worker: OCRJob)
    end
  end
end
