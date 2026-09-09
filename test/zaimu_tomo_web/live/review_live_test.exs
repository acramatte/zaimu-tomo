defmodule ZaimuTomoWeb.ReviewLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.ReviewDecision
  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Repo

  setup :register_and_log_in_user

  setup do
    original_config = Application.get_env(:zaimu_tomo, :langfuse)
    Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")

    on_exit(fn ->
      if original_config do
        Application.put_env(:zaimu_tomo, :langfuse, original_config)
      else
        Application.delete_env(:zaimu_tomo, :langfuse)
      end
    end)

    :ok
  end

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

  test "creates an undecided tax deduction claim when approving an invoice", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    document = document_fixture(scope)
    extracted_content = extracted_content_fixture(document, user)
    review = pending_review_fixture(extracted_content)

    {:ok, show_live, _html} = live(conn, ~p"/reviews/#{review}")
    refute has_element?(show_live, "#approval-form")
    refute has_element?(show_live, "#review-tax-treatment-status")

    show_live
    |> element("button", "Approve & post")
    |> render_click()

    assert [%{tax_deduction_claim: %{status: "undecided"}}] =
             ZaimuTomo.Accounting.list_journal_entries(user.id)
  end

  test "creates an undecided tax deduction claim when amending an invoice", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    document = document_fixture(scope)
    extracted_content = extracted_content_fixture(document, user)
    review = pending_review_fixture(extracted_content)

    {:ok, edit_live, _html} = live(conn, ~p"/reviews/#{review}/edit")
    refute has_element?(edit_live, "#review-tax-treatment-status")

    edit_live
    |> form("#review_form", %{
      "review_decision" => %{"review_notes" => "Reviewed"},
      "decision_data" => %{
        "issuer" => "ACME Corp",
        "invoice_number" => "INV-001",
        "invoice_date" => "2026-05-08",
        "amount_to_pay_cents" => "4200",
        "currency" => "EUR",
        "reason_for_payment" => "Office supplies"
      }
    })
    |> render_submit()

    assert [%{tax_deduction_claim: %{status: "undecided"}}] =
             ZaimuTomo.Accounting.list_journal_entries(user.id)
  end

  test "shows the extraction feedback widget only when a Langfuse trace exists", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    document = document_fixture(scope)

    traced_content =
      extracted_content_fixture(document, user, %{
        trace_id: "abc123def456abc123def456abc123def4"
      })

    traced_review = pending_review_fixture(traced_content)

    {:ok, _show_live, traced_html} = live(conn, ~p"/reviews/#{traced_review}")
    assert traced_html =~ "Extraction feedback"
    assert traced_html =~ "👍 Correct"
    assert traced_html =~ "👎 Incorrect"

    untraced_content = extracted_content_fixture(document, user)
    untraced_review = pending_review_fixture(untraced_content)

    {:ok, _show_live, untraced_html} = live(conn, ~p"/reviews/#{untraced_review}")
    refute untraced_html =~ "Extraction feedback"
  end

  test "records correct-extraction feedback with a comment", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        trace_id: "abc123def456abc123def456abc123def4"
      })

    review = pending_review_fixture(extracted_content)

    {:ok, show_live, _html} = live(conn, ~p"/reviews/#{review}")

    show_live
    |> element("button", "👍 Correct")
    |> render_click()

    assert show_live
           |> form("#feedback_form", feedback: %{comment: "Amount matched the PDF"})
           |> render_submit() =~ "Your feedback has been recorded."
  end

  test "records incorrect-extraction feedback without a comment", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        trace_id: "abc123def456abc123def456abc123def4"
      })

    review = pending_review_fixture(extracted_content)

    {:ok, show_live, _html} = live(conn, ~p"/reviews/#{review}")

    show_live
    |> element("button", "👎 Incorrect")
    |> render_click()

    assert show_live
           |> form("#feedback_form", feedback: %{comment: "The amount was parsed incorrectly"})
           |> render_submit() =~ "Your feedback has been recorded."
  end

  describe "duplicate invoice detection" do
    @base_data %{
      amount_to_pay_cents: 4200,
      invoice_date: "2026-06-09",
      invoice_number: "INV-777",
      currency: "CHF",
      reason_for_payment: "Office supplies",
      issuer: "Acme Corp"
    }

    test "blocks approval of an exact duplicate and links to the recorded entry", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      original_document = document_fixture(scope)

      original_content =
        extracted_content_fixture(original_document, user, %{extracted_data: @base_data})

      {:ok, _} = Review.create_initial_decision(original_content)
      {:ok, _} = Review.approve_invoice(original_content.id, user.id)

      duplicate_document = document_fixture(scope)

      duplicate_content =
        extracted_content_fixture(duplicate_document, user, %{extracted_data: @base_data})

      review = pending_review_fixture(duplicate_content)

      {:ok, show_live, html} = live(conn, ~p"/reviews/#{review}")

      assert html =~ "Invoice already recorded"
      assert html =~ "INV-777"
      refute has_element?(show_live, "button", "Approve & post")
      assert has_element?(show_live, "a", "Open entry")

      # Approving through the (now hidden) action is refused at the context
      # level too: the review stays pending and no entry appears.
      render_click(show_live, "approve")
      decision = Repo.get!(ReviewDecision, review.id)
      assert decision.review_status == "pending"
      assert Accounting.get_journal_entry_for_decision(review.id) == :error
    end

    test "warns but allows posting for an unnumbered tuple match", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      original_document = document_fixture(scope)

      original_content =
        extracted_content_fixture(original_document, user, %{
          extracted_data: Map.merge(@base_data, %{invoice_number: nil})
        })

      {:ok, _} = Review.create_initial_decision(original_content)
      {:ok, _} = Review.approve_invoice(original_content.id, user.id)

      duplicate_document = document_fixture(scope)

      duplicate_content =
        extracted_content_fixture(duplicate_document, user, %{
          extracted_data: Map.merge(@base_data, %{invoice_number: nil})
        })

      review = pending_review_fixture(duplicate_content)

      {:ok, show_live, html} = live(conn, ~p"/reviews/#{review}")

      assert html =~ "Possible duplicate"
      assert has_element?(show_live, "button", "Approve & post")
    end

    test "never shows another user's entry as a candidate", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      other_user = user_fixture()
      other_scope = user_scope_fixture(other_user)
      other_document = document_fixture(other_scope)

      other_content =
        extracted_content_fixture(other_document, other_user, %{extracted_data: @base_data})

      {:ok, _} = Review.create_initial_decision(other_content)
      {:ok, _} = Review.approve_invoice(other_content.id, other_user.id)

      document = document_fixture(scope)
      content = extracted_content_fixture(document, user, %{extracted_data: @base_data})
      review = pending_review_fixture(content)

      {:ok, show_live, html} = live(conn, ~p"/reviews/#{review}")

      refute html =~ "Invoice already recorded"
      refute html =~ "Possible duplicate"
      assert has_element?(show_live, "button", "Approve & post")
    end

    test "flags a strong duplicate when the amended data matches a recorded invoice", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      document = document_fixture(scope)

      content =
        extracted_content_fixture(document, user, %{
          extracted_data: Map.merge(@base_data, %{invoice_number: "INV-OTHER"})
        })

      review = pending_review_fixture(content)

      original_document = document_fixture(scope)

      original_content =
        extracted_content_fixture(original_document, user, %{extracted_data: @base_data})

      {:ok, _} = Review.create_initial_decision(original_content)
      {:ok, _} = Review.approve_invoice(original_content.id, user.id)

      {:ok, edit_live, _html} = live(conn, ~p"/reviews/#{review}/edit")

      message =
        edit_live
        |> form("#review_form", %{
          "review_decision" => %{"review_notes" => "Amended"},
          "decision_data" => %{
            "issuer" => "Acme Corp",
            "invoice_number" => "INV-777",
            "invoice_date" => "2026-06-09",
            "amount_to_pay_cents" => "4200",
            "currency" => "CHF",
            "reason_for_payment" => "Amended data"
          }
        })
        |> render_submit()

      assert message =~ "Invoice already recorded"
      assert render(edit_live) =~ "This invoice number is already recorded for this issuer"
    end

    test "posts successfully when the amended data has no duplicate", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      document = document_fixture(scope)

      content =
        extracted_content_fixture(document, user, %{
          extracted_data: Map.merge(@base_data, %{invoice_number: "INV-OTHER"})
        })

      review = pending_review_fixture(content)

      {:ok, edit_live, _html} = live(conn, ~p"/reviews/#{review}/edit")

      assert {:error, {:redirect, %{to: to}}} =
               edit_live
               |> form("#review_form", %{
                 "review_decision" => %{"review_notes" => "Amended"},
                 "decision_data" => %{
                   "issuer" => "Acme Corp",
                   "invoice_number" => "INV-999",
                   "invoice_date" => "2026-06-09",
                   "amount_to_pay_cents" => "4200",
                   "currency" => "CHF",
                   "reason_for_payment" => "Amended data"
                 }
               })
               |> render_submit()

      assert to =~ "/journal_entries/"
    end
  end
end
