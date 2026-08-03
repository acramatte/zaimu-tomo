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

  test "shows verifier concerns for a rejected extraction", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        analysis: %{
          "verification" => %{
            "status" => "rejected",
            "field_issues" => "amount_to_pay_cents,currency",
            "reason" => "The OCR shows a total amount of 0.00 in both USD and CHF."
          }
        }
      })

    review = pending_review_fixture(extracted_content)

    {:ok, _show_live, html} = live(conn, ~p"/reviews/#{review}")

    assert html =~ "Verifier flagged this extraction"
    assert html =~ "Rejected"
    assert html =~ "amount_to_pay_cents,currency"
    assert html =~ "The OCR shows a total amount of 0.00 in both USD and CHF."
  end

  test "shows a verifier failure that needs human review", %{conn: conn, scope: scope, user: user} do
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        analysis: %{
          "verification" => %{
            "status" => "verification_failed",
            "reason" => "Verifier did not return valid structured output."
          }
        }
      })

    review = pending_review_fixture(extracted_content)

    {:ok, _show_live, html} = live(conn, ~p"/reviews/#{review}")

    assert html =~ "Verifier flagged this extraction"
    assert html =~ "Could not verify"
    assert html =~ "Verifier did not return valid structured output."
  end

  test "asks for a rejection reason before rejecting", %{conn: conn, scope: scope, user: user} do
    document = document_fixture(scope)
    extracted_content = extracted_content_fixture(document, user)
    review = pending_review_fixture(extracted_content)

    {:ok, show_live, _html} = live(conn, ~p"/reviews/#{review}")

    assert show_live
           |> element("button", "Reject")
           |> render_click() =~ "Why are you rejecting this invoice?"

    assert show_live
           |> form("#rejection_form", review_decision: %{rejection_reason: ""})
           |> render_submit() =~ "can&#39;t be blank"
  end
end
