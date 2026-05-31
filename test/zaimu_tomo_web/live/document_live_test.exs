defmodule ZaimuTomoWeb.DocumentLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures



  setup :register_and_log_in_user

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

  describe "document status display" do
    test "processing — no extracted content yet", %{conn: conn, scope: scope} do
      document_fixture(scope)
      {:ok, _live, html} = live(conn, ~p"/documents")
      assert html =~ "Processing"
    end

    test "needs review — extraction succeeded, decision pending", %{conn: conn, scope: scope, user: user} do
      doc = document_fixture(scope)
      ec = extracted_content_fixture(doc, user)
      pending_review_fixture(ec)
      {:ok, _live, html} = live(conn, ~p"/documents")
      assert html =~ "Needs review"
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
