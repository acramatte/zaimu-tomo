defmodule ZaimuTomoWeb.ReviewLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  setup :register_and_log_in_user

  test "renders pending review amounts with their extracted currency", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        extracted_data: %{
          amount_to_pay_cents: 12_345,
          invoice_date: "2026-05-08",
          invoice_number: "INV-USD-001",
          currency: "USD",
          reason_for_payment: "Software subscription",
          issuer: "Example Corp"
        }
      })

    review = pending_review_fixture(extracted_content)

    {:ok, _index_live, index_html} = live(conn, ~p"/reviews")
    assert index_html =~ "USD 123.45"
    refute index_html =~ "€123.45"

    {:ok, _show_live, show_html} = live(conn, ~p"/reviews/#{review}")
    assert show_html =~ "USD 123.45"
    refute show_html =~ "€123.45"
  end
end
