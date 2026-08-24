defmodule ZaimuTomoWeb.DocumentPreviewClickTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import ZaimuTomo.DocumentsFixtures

  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory
  alias ZaimuTomo.Documents

  setup :register_and_log_in_user

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)
  end

  test "clicking the Preview link redirects to the index with preview query param and renders preview pane without reading storage", %{
    conn: conn,
    scope: scope
  } do
    document = document_fixture(scope)

    # ensure memory store is empty
    assert [] = :ets.tab2list(Memory)

    {:ok, index_live, html} = live(conn, ~p"/documents")

    IO.puts("---INITIAL HTML---")
    IO.puts(html)
    IO.puts("---END HTML---")

    log = capture_log(fn ->
      # click the Preview link as the user would
      result =
        index_live
        |> element("#documents-#{document.id} a", "Preview")
        |> render_click()

      # follow the redirect that the link triggers
      {:ok, _index_live_after, html_after} = follow_redirect(result, conn, ~p"/documents?preview=#{document.id}")

      IO.puts("---AFTER HTML---")
      IO.puts(html_after)
      IO.puts("---END AFTER HTML---")

      # the preview pane should be rendered (iframe/img src present or not)
      assert html_after =~ "doc-preview"

      # still no storage reads should have occurred at this point (iframe src not fetched by the test)
      assert [] = :ets.tab2list(Memory)
    end)

    IO.puts("---CAPTURED LOGS---")
    IO.puts(log)
    IO.puts("---END LOGS---")
  end

  test "preview endpoint logs on storage read failure and returns 503", %{conn: conn, scope: scope} do
    # create a previewable document (PDF) but do not put the object into storage
    document = document_fixture(scope, %{filename: "invoice.pdf", object_key: "documents/missing.pdf"})

    # ensure memory store is empty
    Memory.reset()
    assert [] = :ets.tab2list(Memory)

    # sanity check: document exists in the context
    assert Documents.get_document!(scope, document.id)

    log = capture_log(fn ->
      # ensure conn has current_scope assigned for controller
      conn = Plug.Conn.assign(conn, :current_scope, scope)

      conn = get(conn, ~p"/documents/#{document.id}/preview")

      # controller should return 503 Service Unavailable when storage read fails
      assert response(conn, 503) =~ "Service unavailable"
    end)

    # log should contain the controller's error message with document id
    assert log =~ "Document preview failed for id=#{document.id}"
  end
end
