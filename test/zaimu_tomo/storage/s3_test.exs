defmodule ZaimuTomo.Storage.S3Test do
  use ExUnit.Case, async: true

  alias ZaimuTomo.Storage.S3

  @req_stub ZaimuTomo.Storage.S3Test

  setup {Req.Test, :verify_on_exit!}

  test "puts through a path-style endpoint with signed headers and inferred content type" do
    Req.Test.stub(@req_stub, fn conn ->
      assert conn.method == "PUT"
      assert conn.host == "rustfs.test"
      assert conn.port == 9000
      assert conn.request_path == "/zaimu-tomo-test/documents/invoice%202026.pdf"
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/pdf"]
      assert [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      assert String.starts_with?(authorization, "AWS4-HMAC-SHA256 Credential=access-key/")
      assert [_] = Plug.Conn.get_req_header(conn, "x-amz-date")
      assert [_] = Plug.Conn.get_req_header(conn, "x-amz-content-sha256")
      assert Req.Test.raw_body(conn) == "invoice bytes"

      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, "documents/invoice 2026.pdf"} =
             S3.put_object("documents/invoice 2026.pdf", "invoice bytes", path_style_config())
  end

  test "uses a virtual-hosted endpoint and application/octet-stream fallback" do
    Req.Test.stub(@req_stub, fn conn ->
      assert conn.method == "PUT"
      assert conn.host == "zaimu-tomo-test.objects.test"
      assert conn.request_path == "/documents/receipt.unknown"
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/octet-stream"]

      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, "documents/receipt.unknown"} =
             S3.put_object("documents/receipt.unknown", "bytes", virtual_hosted_config())
  end

  test "streams a GET response to the requested path" do
    Req.Test.stub(@req_stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/zaimu-tomo-test/documents/invoice.pdf"
      Plug.Conn.send_resp(conn, 200, "downloaded bytes")
    end)

    destination =
      Path.join(System.tmp_dir!(), "zaimu-s3-#{System.unique_integer([:positive])}.pdf")

    on_exit(fn -> File.rm(destination) end)

    assert {:ok, ^destination} =
             S3.get_object("documents/invoice.pdf", destination, path_style_config())

    assert File.read!(destination) == "downloaded bytes"
  end

  test "returns a filesystem error when the destination cannot be opened" do
    Req.Test.stub(@req_stub, fn conn ->
      assert conn.method == "GET"
      Plug.Conn.send_resp(conn, 200, "downloaded bytes")
    end)

    destination =
      Path.join(
        System.tmp_dir!(),
        "zaimu-s3-missing-#{System.unique_integer([:positive])}/invoice.pdf"
      )

    assert {:error, :enoent} =
             S3.get_object("documents/invoice.pdf", destination, path_style_config())
  end

  test "maps a missing object and successful deletion" do
    Req.Test.expect(@req_stub, fn conn ->
      assert conn.method == "HEAD"
      Plug.Conn.send_resp(conn, 404, "")
    end)

    Req.Test.expect(@req_stub, fn conn ->
      assert conn.method == "DELETE"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert {:error, :not_found} = S3.head_object("documents/missing.pdf", path_style_config())
    assert :ok = S3.delete_object("documents/missing.pdf", path_style_config())
  end

  defp path_style_config do
    [
      endpoint: "http://rustfs.test:9000",
      region: "eu-central-1",
      access_key_id: "access-key",
      secret_access_key: "secret-key",
      bucket: "zaimu-tomo-test",
      path_style: true,
      req_options: [plug: {Req.Test, @req_stub}]
    ]
  end

  defp virtual_hosted_config do
    [
      endpoint: "https://objects.test",
      region: "fsn1",
      access_key_id: "access-key",
      secret_access_key: "secret-key",
      bucket: "zaimu-tomo-test",
      path_style: false,
      req_options: [plug: {Req.Test, @req_stub}]
    ]
  end
end
