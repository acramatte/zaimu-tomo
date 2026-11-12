defmodule ZaimuTomoWeb.DashboardLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ZaimuTomo.Documents
  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  @req_stub __MODULE__

  setup :register_and_log_in_user

  test "renders the dashboard as a LiveView", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Good morning, there"
  end

  test "labels navigation items for the folded sidebar", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "class=\"nav-label\">Dashboard"
    assert html =~ "data-tooltip=\"Dashboard\""
    assert html =~ "aria-label=\"Dashboard\""
    assert html =~ "class=\"nav-item active\""
    assert html =~ "class=\"nav-active-marker\""
    assert html =~ "class=\"btn sm ghost sidebar-toggle\""
    assert html =~ "id=\"sidebar-toggle\""
  end

  describe "recent activity" do
    setup do
      Memory.reset()
      on_exit(&Memory.reset/0)

      original_langfuse = Application.get_env(:zaimu_tomo, :langfuse)
      Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")
      on_exit(fn -> Application.put_env(:zaimu_tomo, :langfuse, original_langfuse) end)

      original_mistral = Application.fetch_env!(:zaimu_tomo, :mistral)

      Application.put_env(
        :zaimu_tomo,
        :mistral,
        Keyword.merge(original_mistral,
          api_key: "test-key",
          req_options: [plug: {Req.Test, @req_stub}]
        )
      )

      on_exit(fn -> Application.put_env(:zaimu_tomo, :mistral, original_mistral) end)
    end

    test "a failed attempt turns the open feed's item into a retry with its reason", %{
      conn: conn,
      scope: scope
    } do
      {:ok, retrying} =
        Documents.create_document(scope, %{filename: "a.pdf", object_key: "documents/a.pdf"})

      Storage.put_object("documents/a.pdf", "invoice bytes")

      {:ok, view, _html} = live(conn, ~p"/")
      feed = find_live_child(view, "dashboard-recent-activity")
      item = "#recent-activity-document-#{retrying.id}"

      assert render(element(feed, item)) =~ "Sent to OCR · extraction in progress"
      refute render(element(feed, item)) =~ "Retrying"

      Req.Test.stub(@req_stub, fn conn -> Plug.Conn.send_resp(conn, 504, "timeout") end)
      assert %{failure: 1} = Oban.drain_queue(queue: :documents)

      html = render(element(feed, item))
      assert html =~ "Retrying"

      assert html =~
               "Attempt 2 of 5 · last try: the OCR service returned an error · " <>
                 "next try in under a minute"
    end
  end
end
