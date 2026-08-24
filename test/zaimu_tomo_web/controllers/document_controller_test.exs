defmodule ZaimuTomoWeb.DocumentControllerTest do
  use ZaimuTomoWeb.ConnCase

  import ZaimuTomo.DocumentsFixtures

  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  setup :register_and_log_in_user

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)
  end

  test "preview PDF returns inline PDF bytes and headers", %{conn: conn, scope: scope} do
    document =
      document_fixture(scope, %{filename: "invoice.pdf", object_key: "documents/invoice.pdf"})

    assert {:ok, "documents/invoice.pdf"} = Storage.put_object(document.object_key, "pdf-bytes")

    conn = get(conn, ~p"/documents/#{document.id}/preview")
    assert conn.status == 200
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
    assert get_resp_header(conn, "content-security-policy") == ["frame-ancestors 'self'"]

    assert get_resp_header(conn, "content-type")
           |> List.first()
           |> String.starts_with?("application/pdf")

    assert conn.resp_body == "pdf-bytes"
  end

  test "preview image returns inline image bytes and content-type", %{conn: conn, scope: scope} do
    document =
      document_fixture(scope, %{filename: "photo.jpg", object_key: "documents/photo.jpg"})

    assert {:ok, "documents/photo.jpg"} = Storage.put_object(document.object_key, "jpg-bytes")

    conn = get(conn, ~p"/documents/#{document.id}/preview")
    assert conn.status == 200
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    assert get_resp_header(conn, "content-type") |> List.first() |> String.starts_with?("image/")
    assert conn.resp_body == "jpg-bytes"
  end

  test "preview of non-previewable type returns 415", %{conn: conn, scope: scope} do
    document =
      document_fixture(scope, %{filename: "report.docx", object_key: "documents/report.docx"})

    assert {:ok, "documents/report.docx"} = Storage.put_object(document.object_key, "docx-bytes")

    conn = get(conn, ~p"/documents/#{document.id}/preview")
    assert conn.status == 415
    assert conn.resp_body =~ "Preview not available"
  end

  test "download returns attachment with safe filename and bytes", %{conn: conn, scope: scope} do
    document =
      document_fixture(scope, %{filename: "my invoice.pdf", object_key: "documents/inv.pdf"})

    assert {:ok, "documents/inv.pdf"} = Storage.put_object(document.object_key, "inv-bytes")

    conn = get(conn, ~p"/documents/#{document.id}/download")
    assert conn.status == 200
    assert get_resp_header(conn, "content-disposition") |> List.first() =~ "attachment"

    assert get_resp_header(conn, "content-type")
           |> List.first()
           |> String.starts_with?("application/")

    assert conn.resp_body == "inv-bytes"
  end

  test "unauthorized preview attempt for other user's document returns 404", %{conn: conn} do
    # create another user and document not belonging to current scope
    other_user = ZaimuTomo.AccountsFixtures.user_fixture(%{email: "other@example.com"})
    other_scope = ZaimuTomo.AccountsFixtures.user_scope_fixture(other_user)

    document =
      document_fixture(other_scope, %{filename: "secret.pdf", object_key: "documents/secret.pdf"})

    conn = get(conn, ~p"/documents/#{document.id}/preview")
    assert conn.status == 404
  end
end
