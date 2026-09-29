defmodule ZaimuTomoWeb.ExtractedContentApiRemovedTest do
  use ZaimuTomoWeb.ConnCase, async: true

  # The unauthenticated, unscoped /api/extracted_content routes were removed.
  # Guard against them being reintroduced without authentication.
  describe "removed /api/extracted_content routes" do
    test "GET latest extraction is not routed", %{conn: conn} do
      path = "/api/extracted_content/1/1/latest"

      assert Phoenix.Router.route_info(ZaimuTomoWeb.Router, "GET", path, "localhost") == :error
      assert conn |> get(path) |> Map.fetch!(:status) == 404
    end

    test "POST retry is not routed", %{conn: conn} do
      path = "/api/extracted_content/1/1/retry"

      assert Phoenix.Router.route_info(ZaimuTomoWeb.Router, "POST", path, "localhost") == :error
      assert conn |> post(path) |> Map.fetch!(:status) == 404
    end
  end
end
