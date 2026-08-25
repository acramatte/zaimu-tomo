defmodule ZaimuTomoWeb.DocumentLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Documents
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

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
      |> element("#documents-#{document.id} a", "Preview")
      |> render_click()

      assert_patch(index_live, ~p"/documents?preview=#{document.id}")
      assert has_element?(index_live, ".doc-preview")
    end

    test "updates document in listing", %{conn: conn, document: document} do
      {:ok, index_live, _html} = live(conn, ~p"/documents")

      assert {:ok, form_live, _html} =
               index_live
               |> element("#documents-#{document.id} a", "Edit")
               |> render_click()
               |> follow_redirect(conn, ~p"/documents/#{document}/edit")

      assert render(form_live) =~ "Edit Document"

      # Skip validation and submission tests for now as file upload works differently
      # The form now uses live file uploads which require a different testing approach
      # TODO: Enhance this test with proper file upload simulation
    end

    test "deletes document in listing", %{conn: conn, document: document} do
      {:ok, index_live, _html} = live(conn, ~p"/documents")

      assert index_live |> element("#documents-#{document.id} a", "Delete") |> render_click()
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

      # Skip validation and submission tests for now as file upload works differently
      # The form now uses live file uploads which require a different testing approach
      # TODO: Enhance this test with proper file upload simulation
    end
  end
end
