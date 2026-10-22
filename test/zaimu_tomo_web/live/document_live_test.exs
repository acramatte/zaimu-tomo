defmodule ZaimuTomoWeb.DocumentLiveTest do
  use ZaimuTomoWeb.ConnCase
  use Oban.Testing, repo: ZaimuTomo.Repo

  import Phoenix.LiveViewTest
  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.DocumentProcessing.OCRJob
  alias ZaimuTomo.Documents
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Documents.Fingerprint
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  # Independently computed with `printf '…' | sha256sum`.
  @invoice_bytes_sha256 "f3cbbf0fb1cedd39097a0159ee1b5e1a85fec1efcf8150399a6d25c3cf9739f3"
  @new_bytes_sha256 "11e2defd59f47c7f2aac84d6a5d6747e98e785afffb72c8bb7b05ec74e1d663c"

  setup :register_and_log_in_user

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)
  end

  defp create_document(%{scope: scope}) do
    document = document_fixture(scope)

    %{document: document}
  end

  describe "Index" do
    setup [:create_document]

    test "lists all documents", %{conn: conn, document: document} do
      {:ok, _index_live, html} = live(conn, ~p"/documents")

      assert html =~ "Documents"
      assert html =~ document.filename
    end

    test "selecting a preview via query param does not read storage on index", %{
      conn: conn,
      document: document
    } do
      # ensure memory store is empty and we did not put the object's bytes
      assert [] = :ets.tab2list(Memory)

      {:ok, _index_live, html} = live(conn, ~p"/documents?preview=#{document.id}")

      assert html =~ "Documents"
      # the preview pane is rendered but no storage reads should have occurred
      assert [] = :ets.tab2list(Memory)
    end

    test "clicking Preview patches the index and shows the preview in place", %{
      conn: conn,
      document: document
    } do
      {:ok, index_live, _html} = live(conn, ~p"/documents")

      index_live
      |> element("#documents-#{document.id} [aria-label=\"Preview document\"]")
      |> render_click()

      assert_patch(index_live, ~p"/documents?preview=#{document.id}")
      assert has_element?(index_live, "#document-preview")

      assert has_element?(
               index_live,
               "#document-preview iframe, #document-preview img, #document-preview .doc-modal-empty"
             )
    end

    test "pressing Escape closes the preview", %{conn: conn, document: document} do
      {:ok, index_live, _html} = live(conn, ~p"/documents?preview=#{document.id}")

      assert has_element?(index_live, "#document-preview")

      render_keydown(index_live, "close-preview", %{"key" => "Escape"})

      refute has_element?(index_live, "#document-preview")
    end

    test "updates document in listing", %{conn: conn, document: document} do
      {:ok, index_live, _html} = live(conn, ~p"/documents")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#documents-#{document.id} [aria-label=\"Edit document\"]")
               |> render_click()
               |> follow_redirect(conn, ~p"/documents/#{document}/edit")

      assert render(form_live) =~ "Edit Document"

      # File upload and edit submission are covered in "Form uploads" below.
    end

    test "deletes document in listing", %{conn: conn, document: document} do
      {:ok, index_live, _html} = live(conn, ~p"/documents")

      assert index_live
             |> element("#documents-#{document.id} [aria-label=\"Delete document\"]")
             |> render_click()

      refute has_element?(index_live, "#documents-#{document.id}")
    end
  end

  describe "Form uploads" do
    test "stores a new document through the configured object storage", %{
      conn: conn,
      scope: scope
    } do
      {:ok, live, _html} = live(conn, ~p"/documents/new")

      upload =
        file_input(live, "#document-form", :document, [
          %{
            last_modified: 1_594_171_879_000,
            name: "invoice.pdf",
            content: "invoice bytes",
            size: 13,
            type: "application/pdf"
          }
        ])

      assert render_upload(upload, "invoice.pdf") =~ "100%"

      assert {:error, {:live_redirect, %{to: "/documents"}}} =
               live
               |> form("#document-form")
               |> render_submit()

      [document] = Documents.list_documents(scope)
      assert document.filename == "invoice.pdf"
      assert "documents/" <> _ = document.object_key
      assert :ok = Storage.head_object(document.object_key)

      # The digest is SHA-256 of the uploaded bytes and of the stored object.
      assert document.content_sha256 == @invoice_bytes_sha256
      assert {:ok, stored} = Storage.read_object(document.object_key)
      assert Fingerprint.sha256(stored) == document.content_sha256
    end

    test "the dashboard drop zone stores the digest of the uploaded bytes", %{
      conn: conn,
      scope: scope
    } do
      {:ok, index_live, _html} = live(conn, ~p"/documents")
      upload_live = find_live_child(index_live, "doc-upload")

      upload =
        file_input(upload_live, "#doc-upload-form", :document, [
          %{
            last_modified: 1_594_171_879_000,
            name: "invoice.pdf",
            content: "invoice bytes",
            size: 13,
            type: "application/pdf"
          }
        ])

      assert render_upload(upload, "invoice.pdf") =~ "100%"
      render_hook(upload_live, "save", %{})

      [document] = Documents.list_documents(scope)
      assert document.content_sha256 == @invoice_bytes_sha256
      assert {:ok, "invoice bytes"} = Storage.read_object(document.object_key)
    end

    test "replaces the stored object only after updating the document", %{
      conn: conn,
      scope: scope
    } do
      document = document_fixture(scope, %{object_key: "documents/original.pdf"})

      assert {:ok, "documents/original.pdf"} =
               Storage.put_object(document.object_key, "old bytes")

      {:ok, live, _html} = live(conn, ~p"/documents/#{document}/edit")

      upload =
        file_input(live, "#document-form", :document, [
          %{
            last_modified: 1_594_171_879_000,
            name: "replacement.pdf",
            content: "new bytes",
            size: 9,
            type: "application/pdf"
          }
        ])

      assert render_upload(upload, "replacement.pdf") =~ "100%"

      assert {:error, {:live_redirect, %{to: "/documents"}}} =
               live
               |> form("#document-form")
               |> render_submit()

      updated_document = Documents.get_document!(scope, document.id)
      assert updated_document.filename == "replacement.pdf"
      assert updated_document.object_key != document.object_key
      assert {:error, :not_found} = Storage.head_object(document.object_key)
      assert :ok = Storage.head_object(updated_document.object_key)
      assert updated_document.content_sha256 == @new_bytes_sha256
    end

    test "saving an edit without a new file preserves the digest", %{conn: conn, scope: scope} do
      document = document_fixture(scope, %{content_sha256: @invoice_bytes_sha256})

      {:ok, live, _html} = live(conn, ~p"/documents/#{document}/edit")

      assert {:error, {:live_redirect, %{to: "/documents"}}} =
               live
               |> form("#document-form")
               |> render_submit()

      updated_document = Documents.get_document!(scope, document.id)
      assert updated_document.object_key == document.object_key
      assert updated_document.content_sha256 == @invoice_bytes_sha256
    end

    test "removes a newly stored object when document persistence fails", %{
      conn: conn,
      user: user
    } do
      {:ok, live, _html} = live(conn, ~p"/documents/new")
      Repo.delete!(user)

      upload =
        file_input(live, "#document-form", :document, [
          %{
            last_modified: 1_594_171_879_000,
            name: "invoice.pdf",
            content: "invoice bytes",
            size: 13,
            type: "application/pdf"
          }
        ])

      assert render_upload(upload, "invoice.pdf") =~ "100%"
      assert render_submit(form(live, "#document-form")) =~ "New Document"
      assert [] = :ets.tab2list(Memory)
      assert Repo.aggregate(Document, :count) == 0
    end

    test "never renders the digest", %{conn: conn, scope: scope} do
      document = document_fixture(scope, %{content_sha256: @invoice_bytes_sha256})

      {:ok, _live, index_html} = live(conn, ~p"/documents")
      {:ok, _live, show_html} = live(conn, ~p"/documents/#{document}")

      refute index_html =~ @invoice_bytes_sha256
      refute show_html =~ @invoice_bytes_sha256
    end
  end

  describe "document status display" do
    test "processing — no extracted content yet", %{conn: conn, scope: scope} do
      document_fixture(scope)
      {:ok, _live, html} = live(conn, ~p"/documents")
      assert html =~ "Processing"
    end

    test "needs review — extraction succeeded, decision pending", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      doc = document_fixture(scope)
      ec = extracted_content_fixture(doc, user)
      pending_review_fixture(ec)
      {:ok, _live, html} = live(conn, ~p"/documents")
      assert html =~ "Needs review"
    end

    test "needs review — displays the extracted currency", %{conn: conn, scope: scope, user: user} do
      doc = document_fixture(scope)

      ec =
        extracted_content_fixture(doc, user, %{
          extracted_data: %{
            amount_to_pay_cents: 12_345,
            invoice_date: "2026-05-08",
            invoice_number: "INV-USD-001",
            currency: "USD",
            reason_for_payment: "Software subscription",
            issuer: "Example Corp"
          }
        })

      pending_review_fixture(ec)

      {:ok, _live, html} = live(conn, ~p"/documents")
      assert html =~ "USD 123.45"
      refute html =~ "€123.45"
    end

    test "posted — review approved", %{conn: conn, scope: scope, user: user} do
      doc = document_fixture(scope)
      ec = extracted_content_fixture(doc, user)
      approved_review_fixture(ec, user)
      {:ok, _live, html} = live(conn, ~p"/documents")
      assert html =~ "Posted"
    end

    test "posted — review amended", %{conn: conn, scope: scope, user: user} do
      doc = document_fixture(scope)
      ec = extracted_content_fixture(doc, user)
      amended_review_fixture(ec, user)
      {:ok, _live, html} = live(conn, ~p"/documents")
      assert html =~ "Posted"
    end

    test "failed — extraction failed", %{conn: conn, scope: scope, user: user} do
      doc = document_fixture(scope)
      extracted_content_fixture(doc, user, %{status: "failed"})
      {:ok, _live, html} = live(conn, ~p"/documents")
      assert html =~ "Failed"
    end

    test "failed — review rejected", %{conn: conn, scope: scope, user: user} do
      doc = document_fixture(scope)
      ec = extracted_content_fixture(doc, user)
      rejected_review_fixture(ec, user)
      {:ok, _live, html} = live(conn, ~p"/documents")
      assert html =~ "Failed"
    end
  end

  describe "Show" do
    setup [:create_document]

    test "displays document", %{conn: conn, document: document} do
      {:ok, _show_live, html} = live(conn, ~p"/documents/#{document}")

      assert html =~ document.filename
      assert html =~ document.filename
    end

    test "updates document and returns to show", %{conn: conn, document: document} do
      {:ok, show_live, _html} = live(conn, ~p"/documents/#{document}")

      assert {:ok, form_live, _} =
               show_live
               |> element("a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/documents/#{document}/edit?return_to=show")

      assert render(form_live) =~ "Edit Document"

      # File upload and edit submission are covered in "Form uploads" above.
    end
  end

  describe "Show retry processing" do
    test "a failed extraction shows the retry button and a click enqueues a job", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      doc = document_fixture(scope)
      failed = extracted_content_fixture(doc, user, %{status: "failed"})

      {:ok, show_live, _html} = live(conn, ~p"/documents/#{doc}")

      assert has_element?(show_live, "button[phx-click=retry_processing]")

      show_live |> element("button[phx-click=retry_processing]") |> render_click()

      assert_enqueued(
        worker: OCRJob,
        args: %{document_id: doc.id, currency_hint: "CHF", supersedes_extraction_id: failed.id}
      )

      assert Phoenix.Flash.get(live_flash(show_live), :info) == "Processing restarted"

      # The pill reports the current :processing state, not the failed
      # historical row the retry keeps as history (review finding 82.2).
      assert has_element?(show_live, "span.pill.processing")
      refute has_element?(show_live, "span.pill.failed")
      pill = show_live |> element("span.pill.processing") |> render()
      assert pill =~ "Processing"
      refute pill =~ "Failed"

      # The retry moves the document to :processing, so the button disappears.
      refute has_element?(show_live, "button[phx-click=retry_processing]")
    end

    test "a stuck document shows the stalled copy and the retry button", %{
      conn: conn,
      scope: scope
    } do
      doc = document_fixture(scope)

      {:ok, show_live, html} = live(conn, ~p"/documents/#{doc}")

      assert html =~ "Processing stalled"
      assert has_element?(show_live, "button[phx-click=retry_processing]")

      html = show_live |> element("button[phx-click=retry_processing]") |> render_click()

      assert html =~ "OCR in progress"
      assert_enqueued(worker: OCRJob, args: %{document_id: doc.id, supersedes_extraction_id: nil})
      refute has_element?(show_live, "button[phx-click=retry_processing]")
    end

    test "a document with a live job shows no retry button", %{conn: conn, scope: scope} do
      {:ok, doc} =
        Documents.create_document(scope, %{filename: "a.pdf", object_key: "documents/a.pdf"})

      {:ok, show_live, html} = live(conn, ~p"/documents/#{doc}")

      assert html =~ "OCR in progress"
      refute has_element?(show_live, "button[phx-click=retry_processing]")
    end

    test "an extracted document shows no retry button", %{conn: conn, scope: scope, user: user} do
      doc = document_fixture(scope)
      extracted_content_fixture(doc, user)

      {:ok, show_live, _html} = live(conn, ~p"/documents/#{doc}")

      refute has_element?(show_live, "button[phx-click=retry_processing]")
    end

    test "retrying a document that is not failed or stuck enqueues nothing", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      doc = document_fixture(scope)
      extracted_content_fixture(doc, user)

      {:ok, show_live, _html} = live(conn, ~p"/documents/#{doc}")

      html = render_click(show_live, "retry_processing")

      assert Phoenix.Flash.get(live_flash(show_live), :info) ==
               "Nothing to retry: processing is already running or completed."

      assert html =~ "Needs review"
      refute_enqueued(worker: OCRJob)
    end

    test "a foreign document id is not found", %{conn: conn} do
      foreign = document_fixture(user_scope_fixture())

      assert_error_sent 404, fn -> live(conn, ~p"/documents/#{foreign}") end
    end
  end

  describe "Show refreshes durable terminal state" do
    alias ZaimuTomo.DocumentProcessing.Worker

    @extracted %{
      "amount_to_pay_cents" => 4200,
      "invoice_date" => "2026-05-08",
      "invoice_number" => "INV-1",
      "currency" => "CHF",
      "reason_for_payment" => "Office supplies",
      "issuer" => "ACME Corp"
    }

    # A document whose OCR job is executing, as when the worker is mid-attempt.
    defp executing_document(scope) do
      {:ok, doc} =
        Documents.create_document(scope, %{filename: "a.pdf", object_key: "documents/a.pdf"})

      set_job_state(doc, "executing")
      doc
    end

    defp set_job_state(doc, state) do
      import Ecto.Query

      {1, _} =
        from(j in Oban.Job, where: j.worker == "ZaimuTomo.DocumentProcessing.OCRJob")
        |> where([j], fragment("?->>'document_id' = ?", j.args, ^to_string(doc.id)))
        |> Repo.update_all(set: [state: state])
    end

    # The view polls durable state while processing; wait for a pill to appear.
    defp await_pill(view, selector, attempts \\ 40) do
      cond do
        has_element?(view, selector) -> :ok
        attempts == 0 -> flunk("expected #{selector}, got: #{render(view)}")
        true -> Process.sleep(25) && await_pill(view, selector, attempts - 1)
      end
    end

    test "success broadcast before the job is acknowledged ends in Needs review", %{
      conn: conn,
      scope: scope
    } do
      doc = executing_document(scope)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc}")
      assert has_element?(view, "span.pill.processing")

      # Worker order: persist + broadcast first, Oban acknowledges afterwards.
      {:ok, _content} = Worker.persist_and_emit_success(doc, @extracted, %{}, %{}, nil, "CHF")
      _ = render(view)
      assert has_element?(view, "span.pill.processing")

      set_job_state(doc, "completed")

      await_pill(view, "span.pill.review")
      refute has_element?(view, "span.pill.processing")
    end

    test "failure broadcast before the job is acknowledged ends in Failed", %{
      conn: conn,
      scope: scope
    } do
      doc = executing_document(scope)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc}")

      {:ok, _content} = Worker.persist_and_emit_failure(doc, {:ocr_error, "boom"})
      _ = render(view)
      assert has_element?(view, "span.pill.processing")

      set_job_state(doc, "completed")

      await_pill(view, "span.pill.failed")
      assert has_element?(view, "button[phx-click=retry_processing]")
    end

    test "a cancelled job (failure_not_recorded) leaves the view stalled, not processing", %{
      conn: conn,
      scope: scope
    } do
      doc = executing_document(scope)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc}")
      assert has_element?(view, "span.pill.processing")

      set_job_state(doc, "cancelled")

      await_pill(view, "span.pill:not(.processing)")
      refute has_element?(view, "span.pill.processing")
      assert render(view) =~ "Processing stalled"
      assert has_element?(view, "button[phx-click=retry_processing]")
    end

    test "a discarded job leaves the view stalled, not processing", %{conn: conn, scope: scope} do
      doc = executing_document(scope)
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc}")

      set_job_state(doc, "discarded")

      await_pill(view, "span.pill:not(.processing)")
      assert render(view) =~ "Processing stalled"
      assert has_element?(view, "button[phx-click=retry_processing]")
    end

    test "a failed row stays visible as history once a retry is processing", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      doc = document_fixture(scope)
      extracted_content_fixture(doc, user, %{status: "failed"})
      {:ok, view, _html} = live(conn, ~p"/documents/#{doc}")
      view |> element("button[phx-click=retry_processing]") |> render_click()
      assert has_element?(view, "span.pill.processing")

      set_job_state(doc, "executing")
      Process.sleep(100)
      assert has_element?(view, "span.pill.processing")

      assert Repo.aggregate(
               ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent,
               :count
             ) == 1
    end
  end

  # The flash group lives in the root layout, which `render/1` does not include,
  # so assert flashes through the LiveView's socket assigns.
  defp live_flash(view) do
    %{socket: %{assigns: %{flash: flash}}} = :sys.get_state(view.pid)
    flash
  end
end
