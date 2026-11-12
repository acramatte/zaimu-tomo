defmodule ZaimuTomoWeb.DocumentLiveTest do
  use ZaimuTomoWeb.ConnCase
  use Oban.Testing, repo: ZaimuTomo.Repo

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.DocumentProcessing
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

    test "Preview keeps the active tab", %{conn: conn, scope: scope} do
      document = document_fixture(scope)
      document |> extracted_content_fixture(scope.user) |> pending_review_fixture()

      {:ok, index_live, _html} = live(conn, ~p"/documents?tab=needs_action")

      index_live
      |> element("#documents-#{document.id} [aria-label=\"Preview document\"]")
      |> render_click()

      assert_patch(index_live, ~p"/documents?tab=needs_action&preview=#{document.id}")
    end

    test "an approved invoice that still needs booking is under Needs action", %{
      conn: conn,
      scope: scope
    } do
      document = document_fixture(scope)

      review =
        document |> extracted_content_fixture(scope.user) |> approved_review_fixture(scope.user)

      {:ok, needs_action, _html} = live(conn, ~p"/documents?tab=needs_action")
      assert has_element?(needs_action, "#documents-#{document.id}")

      {:ok, posted, _html} = live(conn, ~p"/documents?tab=posted")
      refute has_element?(posted, "#documents-#{document.id}")

      {:ok, entry} = ZaimuTomo.Accounting.get_journal_entry_for_decision(review.id)
      {:ok, _} = ZaimuTomo.Accounting.post_entry(entry, scope.user.id, "Office", "need")

      {:ok, posted, _html} = live(conn, ~p"/documents?tab=posted")
      assert has_element?(posted, "#documents-#{document.id}")
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

  describe "Index tabs" do
    test "each tab lists only its invoices, and the counts cover all of them", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      other = %{
        amount_to_pay_cents: 100,
        invoice_date: "2026-01-01",
        currency: "CHF",
        reason_for_payment: "Other",
        issuer: "Other AG"
      }

      document_fixture(scope, %{filename: "to-check.pdf"})
      |> extracted_content_fixture(user)
      |> pending_review_fixture()

      document_fixture(scope, %{filename: "posted.pdf"})
      |> extracted_content_fixture(user, %{extracted_data: %{other | issuer: "Posted AG"}})
      |> approved_review_fixture(user)
      |> book_entry(user)

      document_fixture(scope, %{filename: "rejected.pdf"})
      |> extracted_content_fixture(user, %{extracted_data: other})
      |> rejected_review_fixture(user)

      for {tab, shown} <- [
            {"needs_action", "to-check.pdf"},
            {"posted", "posted.pdf"},
            {"rejected", "rejected.pdf"}
          ] do
        {:ok, live, html} = live(conn, ~p"/documents?tab=#{tab}")

        for file <- ["to-check.pdf", "posted.pdf", "rejected.pdf"] do
          assert html =~ file == (file == shown), "#{file} on the #{tab} tab (first render)"
          assert render(live) =~ file == (file == shown), "#{file} on the #{tab} tab"
        end

        assert has_element?(live, "#document-tabs a[aria-current]", "1")
      end

      {:ok, live, _html} = live(conn, ~p"/documents")
      assert has_element?(live, ~s(#document-tabs a[aria-current="page"]), "All")
      assert has_element?(live, "#document-tabs a", "3")
    end

    defp book_entry(review, user) do
      {:ok, entry} = ZaimuTomo.Accounting.get_journal_entry_for_decision(review.id)
      {:ok, _} = ZaimuTomo.Accounting.post_entry(entry, user.id, "Office", "need")
    end
  end

  describe "Index rows" do
    test "a corrected invoice is listed with its posted values", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      ec = scope |> document_fixture() |> extracted_content_fixture(user)
      {:ok, _} = ZaimuTomo.Review.create_initial_decision(ec)

      {:ok, _} =
        ZaimuTomo.Review.amend_invoice(
          ec.id,
          user.id,
          ec.extracted_data
          |> Map.from_struct()
          |> Map.merge(%{issuer: "ACME Corporation", amount_to_pay_cents: 3990}),
          nil,
          booking: %{category: "Office", need_or_want: "need"}
        )

      {:ok, _live, html} = live(conn, ~p"/documents?tab=posted")
      assert html =~ "ACME Corporation"
      assert html =~ "EUR 39.90"
      refute html =~ "EUR 42.00"
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

    test "rejected — review rejected", %{conn: conn, scope: scope, user: user} do
      doc = document_fixture(scope)
      ec = extracted_content_fixture(doc, user)
      rejected_review_fixture(ec, user)
      {:ok, _live, html} = live(conn, ~p"/documents")
      assert html =~ "Rejected: Duplicate invoice"
    end
  end

  describe "retry visibility" do
    defp uploaded_document(scope, filename) do
      {:ok, document} =
        Documents.create_document(scope, %{filename: filename, object_key: "documents/a.pdf"})

      document
    end

    # The job as Oban and AttemptOutcomes leave it after attempt 1 failed with
    # this failure code.
    defp waiting_to_retry(document, code) do
      {1, _} =
        from(j in Oban.Job,
          where: fragment("?->>'document_id' = ?", j.args, ^to_string(document.id))
        )
        |> Repo.update_all(
          set: [
            state: "retryable",
            attempt: 1,
            scheduled_at: DateTime.add(DateTime.utc_now(), 20),
            meta: %{"trigger" => "upload", "last_error" => code}
          ]
        )
    end

    test "the list says which attempt a retrying document is on and why", %{
      conn: conn,
      scope: scope
    } do
      retrying = uploaded_document(scope, "retrying.pdf")
      waiting_to_retry(retrying, "llm_request_failed:http_429")
      plain = uploaded_document(scope, "plain.pdf")

      {:ok, view, _html} = live(conn, ~p"/documents")

      row = view |> element("#documents-#{retrying.id}") |> render()
      assert row =~ "Retrying"

      assert row =~
               "Attempt 2 of 5 · last try: the extraction service was rate-limited · " <>
                 "next try in under a minute"

      row = view |> element("#documents-#{plain.id}") |> render()
      assert row =~ "Processing"
      assert row =~ "Sent to OCR · extraction in progress"
      refute row =~ "Retrying"
      refute row =~ "Attempt"
    end

    test "a retry started from the invoice page shows on the page and in the list", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      doc = document_fixture(scope)

      failed =
        extracted_content_fixture(doc, user, %{
          status: "failed",
          error_details: %{"message" => "Image too blurry"}
        })

      {:ok, show_live, _html} = live(conn, ~p"/documents/#{doc}")
      refute has_element?(show_live, "#invoice-earlier-attempts")

      show_live |> element("button[phx-click=retry_processing]") |> render_click()

      assert show_live |> element("#invoice-status") |> render() =~ "Retrying"

      assert show_live |> element("#invoice-retry") |> render() =~
               "Retrying after a failed run · attempt 1 of 5"

      earlier = show_live |> element("#invoice-earlier-attempts") |> render()
      assert earlier =~ "Image too blurry"
      assert earlier =~ Calendar.strftime(failed.inserted_at, "%d %b %Y %H:%M")

      {:ok, list_live, _html} = live(conn, ~p"/documents")
      row = list_live |> element("#documents-#{doc.id}") |> render()
      assert row =~ "Retrying after a failed run · attempt 1 of 5"
      assert row =~ "earlier run failed: Image too blurry"
    end

    test "a first attempt shows no retry on the invoice page", %{conn: conn, scope: scope} do
      doc = uploaded_document(scope, "first.pdf")

      {:ok, show_live, _html} = live(conn, ~p"/documents/#{doc}")

      assert show_live |> element("#invoice-status") |> render() =~ "Processing"
      refute has_element?(show_live, "#invoice-retry")
      refute has_element?(show_live, "#invoice-earlier-attempts")
    end
  end

  describe "Show" do
    setup [:create_document]

    test "displays document", %{conn: conn, document: document} do
      {:ok, _show_live, html} = live(conn, ~p"/documents/#{document}")

      assert html =~ document.filename
      assert html =~ document.filename
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
      assert pill =~ "Retrying"
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
      doc |> extracted_content_fixture(user) |> pending_review_fixture()

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

  describe "durable processing state on Index and the processing hero" do
    defp live_ocr_job(doc),
      do: doc |> DocumentProcessing.ocr_job("CHF", nil) |> Oban.insert!()

    test "a failed document with a live re-run shows Processing and keeps the failure",
         %{conn: conn, scope: scope, user: user} do
      doc = document_fixture(scope)

      extracted_content_fixture(doc, user, %{
        status: "failed",
        error_details: %{"message" => "OCR provider timed out"}
      })

      live_ocr_job(doc)

      {:ok, live, _html} = live(conn, ~p"/documents")
      row = live |> element("#documents-#{doc.id}") |> render()

      assert row =~ "pill processing"
      refute row =~ "pill failed"
      assert row =~ "OCR provider timed out"
    end

    test "a document without a live job and without an extraction shows as stalled",
         %{conn: conn, scope: scope} do
      doc = document_fixture(scope)

      {:ok, live, _html} = live(conn, ~p"/documents")
      row = live |> element("#documents-#{doc.id}") |> render()

      assert row =~ "Processing stalled"
      refute row =~ "pill processing"
      refute has_element?(live, ".processing-hero")
    end

    test "a successful extraction is not shown as processing", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      doc = document_fixture(scope)
      ec = extracted_content_fixture(doc, user)
      pending_review_fixture(ec)

      {:ok, live, _html} = live(conn, ~p"/documents")

      assert live |> element("#documents-#{doc.id}") |> render() =~ "Needs review"
      refute has_element?(live, ".processing-hero")
    end

    test "the Index row and hero update after a Retry from Show without a reload", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      doc = document_fixture(scope)
      extracted_content_fixture(doc, user, %{status: "failed"})

      {:ok, index_live, _html} = live(conn, ~p"/documents")
      assert index_live |> element("#documents-#{doc.id}") |> render() =~ "pill failed"
      refute has_element?(index_live, ".processing-hero")

      {:ok, show_live, _html} = live(conn, ~p"/documents/#{doc}")
      show_live |> element("button[phx-click=retry_processing]") |> render_click()

      assert render(index_live) =~ "pill processing"
      row = index_live |> element("#documents-#{doc.id}") |> render()
      assert row =~ "pill processing"
      refute row =~ "pill failed"
      assert has_element?(index_live, ".processing-hero")
    end

    test "the hero follows live jobs, not the upload age", %{conn: conn, scope: scope, user: user} do
      running = document_fixture(scope, %{filename: "running.pdf"})
      live_ocr_job(running)

      Repo.update_all(from(d in Document, where: d.id == ^running.id),
        set: [inserted_at: ~U[2026-01-01 00:00:00Z]]
      )

      lost = document_fixture(scope, %{filename: "lost.pdf"})

      failed = document_fixture(scope, %{filename: "failed.pdf"})
      extracted_content_fixture(failed, user, %{status: "failed"})

      {:ok, hero, html} = live_isolated(conn, ZaimuTomoWeb.ProcessingHeroLive)

      assert has_element?(hero, ".processing-hero")
      assert html =~ "running.pdf"
      refute html =~ lost.filename
      refute html =~ "failed.pdf"
    end

    test "the hero shows a failed document again while its retry is live", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      doc = document_fixture(scope, %{filename: "again.pdf"})
      extracted_content_fixture(doc, user, %{status: "failed"})

      {:ok, hero, _html} = live_isolated(conn, ZaimuTomoWeb.ProcessingHeroLive)
      refute has_element?(hero, ".processing-hero")

      {:ok, show_live, _html} = live(conn, ~p"/documents/#{doc}")
      show_live |> element("button[phx-click=retry_processing]") |> render_click()

      assert render(hero) =~ "again.pdf"
      assert has_element?(hero, ".processing-hero")
    end
  end

  # The flash group lives in the root layout, which `render/1` does not include,
  # so assert flashes through the LiveView's socket assigns.
  defp live_flash(view) do
    %{socket: %{assigns: %{flash: flash}}} = :sys.get_state(view.pid)
    flash
  end
end
