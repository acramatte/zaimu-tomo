defmodule ZaimuTomoWeb.InvoicePageTest do
  @moduledoc """
  The invoice page at /documents/:id: checking, correcting, booking and
  posting an extracted invoice in one place, and finding it again afterwards.
  """
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.EventLog
  alias ZaimuTomo.Review.ReviewDecision

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

  @booking %{"category" => "Office", "need_or_want" => "need"}

  defp invoice_path(%ReviewDecision{} = review) do
    review = Repo.preload(review, :extracted_content)
    ~p"/documents/#{review.extracted_content.document_id}"
  end

  defp submit_invoice(live, params) do
    live
    |> form("#invoice-form", invoice: Map.merge(@booking, params))
    |> render_submit()
  end

  # The duplicate panel's confirmation buttons submit the invoice form with
  # `confirm` set to the verdict they confirm.
  defp confirm_invoice(live, verdict, params \\ %{}) do
    live
    |> form("#invoice-form", invoice: Map.merge(@booking, params))
    |> render_submit(%{"confirm" => verdict})
  end

  defp flash(live, key) do
    %{socket: %{assigns: %{flash: flash}}} = :sys.get_state(live.pid)
    Phoenix.Flash.get(flash, key)
  end

  defp entry_for(review) do
    {:ok, entry} = Accounting.get_journal_entry_for_decision(review.id)
    entry
  end

  defp capture_scores do
    parent = self()

    Application.put_env(:zaimu_tomo, :langfuse,
      enabled: true,
      environment: "test",
      score_sender: fn payload ->
        send(parent, {:score_payload, payload})
        {:ok, %{status: 200}}
      end
    )
  end

  describe "check and book" do
    test "posts an unchanged invoice already booked, with comment and tax treatment", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope |> document_fixture() |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))

      _html =
        submit_invoice(live, %{
          "comment" => "Checked against the PDF",
          "tax_treatment_status" => "candidate"
        })

      assert flash(live, :info) == "Invoice posted to the journal"
      assert has_element?(live, "#invoice-posted")
      assert has_element?(live, "#invoice-comment-display", "Checked against the PDF")
      assert has_element?(live, "#invoice-tax-treatment", "Potentially deductible")
      assert has_element?(live, "#open-journal-entry")

      assert %ReviewDecision{review_status: "approved", review_notes: "Checked against the PDF"} =
               Repo.get!(ReviewDecision, review.id)

      entry = review |> entry_for() |> Repo.preload(:tax_deduction_claim, force: true)
      assert entry.status == "posted"
      assert entry.category == "Office"
      assert entry.need_or_want == "need"
      assert entry.notes == "Checked against the PDF"
      assert entry.tax_deduction_claim.status == "candidate"
    end

    test "a corrected amount in major units amends the invoice and keeps the extracted value", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope |> document_fixture() |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, html} = live(conn, invoice_path(review))

      # The fixture extracted EUR 42.00; the form shows it in major units.
      assert has_element?(live, ~s(#invoice-amount[value="42.00"]))
      refute html =~ "Extracted <s>"

      assert render_change(live, "validate", %{"invoice" => %{"amount" => "39.90"}}) =~
               "1 corrected"

      submit_invoice(live, %{"amount" => "39.90", "comment" => "Discount on the PDF"})

      assert Repo.get!(ReviewDecision, review.id).review_status == "amended"
      assert entry_for(review).amount_cents == 3990

      # Posted: the corrected value with the extracted one struck through, and
      # the correction in the history.
      assert has_element?(live, "#invoice-posted s", "42.00")
      assert has_element?(live, "#invoice-history", "Amount corrected: 42.00 → 39.90")
    end

    test "undo restores the extracted value", %{conn: conn, scope: scope, user: user} do
      review =
        scope |> document_fixture() |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))

      render_change(live, "validate", %{"invoice" => %{"issuer" => "ACME Corporation"}})
      assert has_element?(live, ".invoice-field.corrected #invoice-issuer")

      live |> element(".invoice-was button", "Undo") |> render_click()
      assert has_element?(live, ~s(#invoice-issuer[value="ACME Corp"]))
      refute has_element?(live, ".invoice-field.corrected")
    end

    test "a booking error posts nothing and leaves the invoice to check", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope |> document_fixture() |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))

      submit_invoice(live, %{"category" => "", "amount" => "39.90"})

      assert flash(live, :error) =~ "Could not post this invoice: category can't be blank"
      assert has_element?(live, "#invoice-form")
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"
      assert Accounting.get_journal_entry_for_decision(review.id) == :error
    end

    test "an unparseable amount is refused before anything is posted", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope |> document_fixture() |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))

      assert submit_invoice(live, %{"amount" => "12,50 CHF"}) =~ "Enter an amount like 89.90"
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"
    end

    test "refuses amounts it would misread or could not store", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope |> document_fixture() |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))

      for amount <- ["1,234", "89.995", "NaN", "Infinity", "1e5", "30000000"] do
        assert submit_invoice(live, %{"amount" => amount}) =~ "Enter an amount like 89.90"
        assert Repo.get!(ReviewDecision, review.id).review_status == "pending"
      end
    end

    test "accepts a decimal comma", %{conn: conn, scope: scope, user: user} do
      review =
        scope |> document_fixture() |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))
      submit_invoice(live, %{"amount" => "39,90"})

      assert entry_for(review).amount_cents == 3990
    end

    test "surrounding whitespace is not a correction", %{conn: conn, scope: scope, user: user} do
      capture_scores()

      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{trace_id: "trace-space"})
        |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))
      submit_invoice(live, %{"issuer" => "ACME Corp "})

      assert Repo.get!(ReviewDecision, review.id).review_status == "approved"
      assert entry_for(review).issuer == "ACME Corp"
      assert_receive {:score_payload, %{traceId: "trace-space", value: 1}}
    end

    test "posting writes the journal entry's audit event", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope |> document_fixture() |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))
      submit_invoice(live, %{"tax_treatment_status" => "candidate"})

      event =
        Repo.get_by!(EventLog,
          event_type: "journal_entry_posted",
          invoice_id: to_string(entry_for(review).id)
        )

      assert event.user_id == user.id

      assert event.metadata == %{
               "category" => "Office",
               "need_or_want" => "need",
               "tax_deduction_status" => "candidate"
             }
    end

    test "an invoice approved before booking was merged can still be booked", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user)
        |> approved_review_fixture(user)

      assert entry_for(review).status == "uncategorized"

      {:ok, live, _html} = live(conn, invoice_path(review))
      assert has_element?(live, "#invoice-booking-form")
      assert has_element?(live, "#invoice-status .pill", "Needs review")

      live
      |> form("#invoice-booking-form",
        invoice: Map.put(@booking, "tax_treatment_status", "not_deductible")
      )
      |> render_submit()

      entry = review |> entry_for() |> Repo.preload(:tax_deduction_claim, force: true)
      assert entry.status == "posted"
      assert entry.tax_deduction_claim.status == "not_deductible"
      assert has_element?(live, "#invoice-tax-treatment", "Not deductible")
      assert has_element?(live, "#invoice-status .pill", "Posted")
    end

    test "a booking sent again after posting is refused and changes nothing", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user)
        |> approved_review_fixture(user)

      {:ok, live, _html} = live(conn, invoice_path(review))

      live
      |> form("#invoice-booking-form",
        invoice: Map.put(@booking, "tax_treatment_status", "candidate")
      )
      |> render_submit()

      refute has_element?(live, "#invoice-booking-form")

      render_hook(live, "book", %{
        "invoice" => %{
          "category" => "Travel",
          "need_or_want" => "want",
          "tax_treatment_status" => "undecided"
        }
      })

      assert flash(live, :error) == "This entry is already booked"

      entry = review |> entry_for() |> Repo.preload(:tax_deduction_claim, force: true)
      assert entry.category == @booking["category"]
      assert entry.need_or_want == @booking["need_or_want"]
      assert entry.tax_deduction_claim.status == "candidate"
    end

    test "rejecting asks for a reason and keeps the invoice findable", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope |> document_fixture() |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))

      assert live |> element("button", "Reject") |> render_click() =~
               "Why are you rejecting this invoice?"

      assert live
             |> form("#rejection_form", review_decision: %{rejection_reason: ""})
             |> render_submit() =~ "can&#39;t be blank"

      live
      |> form("#rejection_form", review_decision: %{rejection_reason: "Paid by my employer"})
      |> render_submit()

      assert has_element?(live, "#invoice-rejected", "Paid by my employer")
      assert Repo.get!(ReviewDecision, review.id).review_status == "rejected"
    end
  end

  describe "extraction feedback" do
    test "posting unchanged data scores the extraction as correct", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      capture_scores()

      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{trace_id: "trace-ok"})
        |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))
      assert has_element?(live, "#extraction-feedback")
      submit_invoice(live, %{"comment" => "private note"})

      assert_receive {:score_payload, %{traceId: "trace-ok", value: 1} = payload}
      refute Map.has_key?(payload, :comment)
    end

    test "corrections score the extraction as incorrect and list the fields, not the comment",
         %{conn: conn, scope: scope, user: user} do
      capture_scores()

      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{trace_id: "trace-fix"})
        |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))
      submit_invoice(live, %{"amount" => "39.90", "comment" => "private note"})

      assert_receive {:score_payload, %{traceId: "trace-fix", value: 0, comment: comment}}
      assert comment =~ "amount_to_pay_cents 4200 -> 3990"
      refute comment =~ "private note"
    end

    test "an explicit choice overrides the automatic score", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      capture_scores()

      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{trace_id: "trace-override"})
        |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))
      live |> element("#extraction-feedback button", "Correct") |> render_click()
      submit_invoice(live, %{"amount" => "39.90"})

      assert_receive {:score_payload, %{traceId: "trace-override", value: 1}}
    end

    test "rejecting sends the explicit choice, never the reason", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      capture_scores()

      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{trace_id: "trace-reject"})
        |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))
      live |> element("#extraction-feedback button", "Incorrect") |> render_click()
      live |> element("button", "Reject") |> render_click()

      live
      |> form("#rejection_form", review_decision: %{rejection_reason: "private reason"})
      |> render_submit()

      assert_receive {:score_payload, %{traceId: "trace-reject", value: 0, comment: comment}}
      refute comment =~ "private reason"
    end

    test "rejecting without a choice sends no score", %{conn: conn, scope: scope, user: user} do
      capture_scores()

      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{trace_id: "trace-silent"})
        |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))
      live |> element("button", "Reject") |> render_click()

      live
      |> form("#rejection_form", review_decision: %{rejection_reason: "Paid by my employer"})
      |> render_submit()

      assert has_element?(live, "#invoice-rejected")
      refute_receive {:score_payload, _payload}, 100
    end

    test "is hidden without a Langfuse trace", %{conn: conn, scope: scope, user: user} do
      review =
        scope |> document_fixture() |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, invoice_path(review))
      refute has_element?(live, "#extraction-feedback")
    end
  end

  describe "page content" do
    test "renders amounts with their extracted currency", %{conn: conn, scope: scope, user: user} do
      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{
          extracted_data: %{
            amount_to_pay_cents: 12_345,
            invoice_date: "2026-05-08",
            invoice_number: "INV-USD-001",
            currency: "USD",
            reason_for_payment: "Software subscription",
            issuer: "Example Corp"
          }
        })
        |> pending_review_fixture()

      {:ok, _live, html} = live(conn, invoice_path(review))
      assert html =~ "USD 123.45"
      refute html =~ "€123.45"
    end

    test "shows the source document so it can be checked against the extracted data", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      pdf = document_fixture(scope, %{filename: "acme-invoice.pdf"})
      pdf |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, ~p"/documents/#{pdf}")
      preview = ~p"/documents/#{pdf}/preview"

      assert has_element?(live, ~s(#review-document-viewer iframe[data-src^="#{preview}#"]))
      assert has_element?(live, ~s(#review-document-card a[href="#{preview}"][target="_blank"]))

      assert has_element?(
               live,
               ~s(#review-document-card a[href="#{~p"/documents/#{pdf}/download"}"])
             )

      docx = document_fixture(scope, %{filename: "notes.docx"})
      docx |> extracted_content_fixture(user) |> pending_review_fixture()

      {:ok, live, _html} = live(conn, ~p"/documents/#{docx}")

      refute has_element?(live, "#review-document-viewer iframe")
      refute has_element?(live, ~s(a[href="#{~p"/documents/#{docx}/preview"}"]))
      assert has_element?(live, "#review-document-card", "Preview not available")
    end

    test "shows verifier concerns for a rejected extraction", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{
          analysis: %{
            "verification" => %{
              "status" => "rejected",
              "field_issues" => "amount_to_pay_cents,currency",
              "reason" => "The OCR shows a total amount of 0.00 in both USD and CHF."
            }
          }
        })
        |> pending_review_fixture()

      {:ok, _live, html} = live(conn, invoice_path(review))

      assert html =~ "Verifier flagged this extraction"
      assert html =~ "amount_to_pay_cents,currency"
      assert html =~ "The OCR shows a total amount of 0.00 in both USD and CHF."
    end

    test "shows a verifier failure that needs human review", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{
          analysis: %{
            "verification" => %{
              "status" => "verification_failed",
              "reason" => "Verifier did not return valid structured output."
            }
          }
        })
        |> pending_review_fixture()

      {:ok, _live, html} = live(conn, invoice_path(review))

      assert html =~ "Verifier flagged this extraction"
      assert html =~ "Could not verify"
      assert html =~ "Verifier did not return valid structured output."
    end

    test "shows the Jev shadow check without changing the posting controls", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{
          analysis: %{
            "verification" => %{
              "status" => "verified",
              "reason" => "All fields match.",
              "typesafe_shadow" => %{
                "status" => "needs_review",
                "model" => "jev-latest",
                "max_error_probability" => 0.91,
                "review_threshold" => 0.7,
                "field_issues" => "amount_to_pay_cents,issuer",
                "field_probabilities" => %{"amount_to_pay_cents" => 0.91, "issuer" => 0.75}
              }
            }
          }
        })
        |> pending_review_fixture()

      {:ok, live, html} = live(conn, invoice_path(review))

      refute html =~ "Verifier flagged this extraction"
      assert html =~ "Quality checks"
      assert html =~ "Independent check: Needs review"
      assert html =~ "amount_to_pay_cents 0.91"
      assert has_element?(live, "#post-invoice")
      assert has_element?(live, "button", "Reject")
    end

    test "a failed Jev shadow check shows its error", %{conn: conn, scope: scope, user: user} do
      review =
        scope
        |> document_fixture()
        |> extracted_content_fixture(user, %{
          analysis: %{
            "verification" => %{
              "status" => "verified",
              "typesafe_shadow" => %{
                "status" => "verification_failed",
                "error" => "invalid_response"
              }
            }
          }
        })
        |> pending_review_fixture()

      {:ok, _live, html} = live(conn, invoice_path(review))

      refute html =~ "Verifier flagged this extraction"
      assert html =~ "Could not verify"
      assert html =~ "invalid_response"
    end

    test "the journal entry opened from the invoice page goes back to that invoice", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      document = document_fixture(scope)
      review = document |> extracted_content_fixture(user) |> pending_review_fixture()
      {:ok, live, _html} = live(conn, invoice_path(review))
      submit_invoice(live, %{})

      {:ok, entry_live, _html} =
        live |> element("#open-journal-entry") |> render_click() |> follow_redirect(conn)

      assert has_element?(
               entry_live,
               ~s(#journal-entry-back-to-invoice[href="#{~p"/documents/#{document}"}"])
             )

      refute has_element?(entry_live, "a", "← Journal entries")
      refute has_element?(entry_live, "#journal-entry-invoice-link")
    end

    test "the journal entry links back to its invoice", %{conn: conn, scope: scope, user: user} do
      document = document_fixture(scope)
      review = document |> extracted_content_fixture(user) |> approved_review_fixture(user)

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry_for(review)}")

      assert has_element?(
               live,
               ~s(#journal-entry-invoice-link[href="#{~p"/documents/#{document}"}"])
             )

      assert has_element?(live, "a", "← Journal entries")
      refute has_element?(live, "#journal-entry-back-to-invoice")
    end
  end

  describe "retired review URLs" do
    test "redirect to the invoice page", %{conn: conn, scope: scope, user: user} do
      document = document_fixture(scope)
      review = document |> extracted_content_fixture(user) |> pending_review_fixture()

      assert redirected_to(get(conn, ~p"/reviews/#{review}")) == ~p"/documents/#{document}"
      assert redirected_to(get(conn, ~p"/reviews/#{review}/edit")) == ~p"/documents/#{document}"
      assert redirected_to(get(conn, ~p"/reviews")) == ~p"/documents?tab=needs_action"
    end

    test "never reveal another user's invoice", %{conn: conn} do
      other = user_fixture()

      review =
        other
        |> user_scope_fixture()
        |> document_fixture()
        |> extracted_content_fixture(other)
        |> pending_review_fixture()

      assert redirected_to(get(conn, ~p"/reviews/#{review}")) == ~p"/documents"
    end
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

    defp post_invoice(scope, user, data) do
      content = extracted_content_fixture(document_fixture(scope), user, %{extracted_data: data})
      {:ok, _} = Review.create_initial_decision(content)
      {:ok, _} = Review.approve_invoice(content.id, user.id)
    end

    defp pending_review(scope, user, data) do
      scope
      |> document_fixture()
      |> extracted_content_fixture(user, %{extracted_data: data})
      |> pending_review_fixture()
    end

    test "refuses to post an exact duplicate and links to the recorded entry", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      post_invoice(scope, user, @base_data)
      review = pending_review(scope, user, @base_data)

      {:ok, live, html} = live(conn, invoice_path(review))

      assert html =~ "Invoice already recorded"
      assert has_element?(live, "a", "Open entry")
      refute has_element?(live, "button", "Post anyway")

      submit_invoice(live, %{})
      assert flash(live, :error) =~ "This invoice number has already been recorded"
      confirm_invoice(live, "possible")

      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"
      assert Accounting.get_journal_entry_for_decision(review.id) == :error
    end

    test "warns about an unnumbered tuple match and posts only through Post anyway", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      unnumbered = Map.put(@base_data, :invoice_number, nil)
      post_invoice(scope, user, unnumbered)
      review = pending_review(scope, user, unnumbered)

      {:ok, live, html} = live(conn, invoice_path(review))
      assert html =~ "Possible duplicate"

      # Post alone re-checks and asks again instead of posting.
      assert submit_invoice(live, %{}) =~ "Post anyway"
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"

      assert has_element?(live, ~s(button[form="invoice-form"][value="possible"]), "Post anyway")
      confirm_invoice(live, "possible")
      assert entry_for(review).status == "posted"
    end

    test "Enter submits through a default button, never a duplicate confirmation", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      unnumbered = Map.put(@base_data, :invoice_number, nil)
      post_invoice(scope, user, unnumbered)
      review = pending_review(scope, user, unnumbered)

      {:ok, _live, html} = live(conn, invoice_path(review))

      [first_submit | _] =
        ~r/<button[^>]*form="invoice-form"[^>]*>/
        |> Regex.scan(html)
        |> List.flatten()

      assert first_submit =~ ~s(id="invoice-default-submit")
      refute first_submit =~ ~s(name="confirm")
    end

    test "a refresh re-checks duplicates against the values on screen", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      unnumbered = Map.put(@base_data, :invoice_number, nil)
      post_invoice(scope, user, unnumbered)
      review = pending_review(scope, user, unnumbered)
      review = Repo.preload(review, :extracted_content)

      {:ok, live, _html} = live(conn, invoice_path(review))
      assert has_element?(live, "#duplicate-panel")

      render_change(live, "validate", %{"invoice" => %{"amount" => "39.90"}})
      send(live.pid, %{document_id: review.extracted_content.document_id})
      render(live)

      refute has_element?(live, "#duplicate-panel")
      assert has_element?(live, ~s(#invoice-amount[value="39.90"]))
    end

    test "treats a numbered entry matched by the unnumbered tuple as a possible duplicate", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      post_invoice(scope, user, @base_data)
      review = pending_review(scope, user, Map.put(@base_data, :invoice_number, nil))

      {:ok, live, html} = live(conn, invoice_path(review))

      assert html =~ "Possible duplicate"
      refute html =~ "Invoice already recorded"
      assert has_element?(live, "button", "Post anyway")
    end

    test "renders an unnumbered invoice with a missing amount", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review =
        pending_review(scope, user, %{@base_data | invoice_number: nil, amount_to_pay_cents: nil})

      assert {:ok, _live, html} = live(conn, invoice_path(review))
      refute html =~ "Possible duplicate"
    end

    test "correcting into a possible duplicate posts only through Post anyway", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      unnumbered = Map.put(@base_data, :invoice_number, nil)
      post_invoice(scope, user, unnumbered)
      review = pending_review(scope, user, %{unnumbered | amount_to_pay_cents: 1})

      {:ok, live, html} = live(conn, invoice_path(review))
      refute html =~ "Possible duplicate"

      assert submit_invoice(live, %{"amount" => "42.00"}) =~ "Possible duplicate"
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"

      confirm_invoice(live, "possible", %{"amount" => "42.00"})
      assert Repo.get!(ReviewDecision, review.id).review_status == "amended"
    end

    test "Post anyway re-checks data edited after the warning", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      unnumbered = Map.put(@base_data, :invoice_number, nil)
      post_invoice(scope, user, unnumbered)
      review = pending_review(scope, user, unnumbered)

      {:ok, live, _html} = live(conn, invoice_path(review))
      assert has_element?(live, "button", "Post anyway")

      # Meanwhile an invoice numbered INV-NEW is recorded, and the reviewer
      # types that number: the confirmation no longer applies.
      post_invoice(scope, user, %{@base_data | invoice_number: "INV-NEW"})
      confirm_invoice(live, "possible", %{"invoice_number" => "INV-NEW"})

      assert flash(live, :error) =~ "This invoice number has already been recorded"

      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"
    end

    test "never shows another user's entry as a candidate", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      other = user_fixture()
      post_invoice(user_scope_fixture(other), other, @base_data)
      review = pending_review(scope, user, @base_data)

      {:ok, live, html} = live(conn, invoice_path(review))

      refute html =~ "Invoice already recorded"
      refute html =~ "Possible duplicate"
      submit_invoice(live, %{})
      assert entry_for(review).status == "posted"
    end

    test "flags a strong duplicate when the corrected data matches a recorded invoice", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      review = pending_review(scope, user, %{@base_data | invoice_number: "INV-OTHER"})
      post_invoice(scope, user, @base_data)

      {:ok, live, _html} = live(conn, invoice_path(review))

      html = submit_invoice(live, %{"invoice_number" => "INV-777"})
      assert html =~ "Invoice already recorded"
      assert html =~ "This invoice number is already recorded for this issuer"
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"
    end
  end

  describe "exact-file duplicate detection" do
    @digest String.duplicate("f", 64)

    @rent %{
      amount_to_pay_cents: 150_000,
      invoice_date: "2026-05-01",
      invoice_number: nil,
      currency: "CHF",
      reason_for_payment: "Rent",
      issuer: "Landlord AG"
    }

    defp post_file_invoice(scope, user, digest, data) do
      content =
        extracted_content_fixture(document_fixture(scope, %{content_sha256: digest}), user, %{
          extracted_data: data
        })

      {:ok, _} = Review.create_initial_decision(content)
      {:ok, decision} = Review.approve_invoice(content.id, user.id)
      {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)
      entry
    end

    defp pending_file_review(scope, user, digest, data) do
      document_fixture(scope, %{content_sha256: digest})
      |> extracted_content_fixture(user, %{extracted_data: data})
      |> pending_review_fixture()
    end

    test "blocks the same file with the same facts and directs the reviewer to reject", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry = post_file_invoice(scope, user, @digest, @rent)
      review = pending_file_review(scope, user, @digest, @rent)

      {:ok, live, html} = live(conn, invoice_path(review))

      assert html =~ "Same file already recorded"
      assert html =~ "Reject this duplicate review."
      assert has_element?(live, ".duplicate-reason", "Same file")
      assert has_element?(live, ~s|a[href="/journal_entries/#{entry.id}"]|, "Open entry")
      refute has_element?(live, "#confirm-file-reuse")
      refute html =~ @digest

      # A crafted confirmation is refused by the view and the context alike.
      confirm_invoice(live, "file_reuse")
      assert render(live) =~ "Reject this duplicate review."
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"
      assert Accounting.get_journal_entry_for_decision(review.id) == :error
    end

    test "asks to confirm a reuse when only the file matches, and posts after confirmation", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      original = post_file_invoice(scope, user, @digest, @rent)

      review =
        pending_file_review(scope, user, @digest, %{
          @rent
          | issuer: "Landlord A.G.",
            amount_to_pay_cents: 15_000
        })

      {:ok, live, html} = live(conn, invoice_path(review))

      assert html =~ "Is this a reused bill for a new period?"
      assert html =~ Calendar.strftime(original.inserted_at, "%Y-%m-%d")
      refute has_element?(live, "button", "Post anyway")

      # Post alone does not post an exact-file match.
      submit_invoice(live, %{})
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"

      confirm_invoice(live, "file_reuse")

      entry = entry_for(review)
      assert entry.source_file_reuse_confirmed
      assert entry.source_document_sha256 == @digest
      assert entry.status == "posted"
    end

    test "a reused QR-bill becomes confirmable after correcting the date", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      _original = post_file_invoice(scope, user, @digest, @rent)
      review = pending_file_review(scope, user, @digest, @rent)

      {:ok, live, html} = live(conn, invoice_path(review))
      assert html =~ "Reject this duplicate review."
      refute has_element?(live, "#confirm-file-reuse")

      assert submit_invoice(live, %{"invoice_date" => "2026-06-01"}) =~
               "Is this a reused bill for a new period?"

      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"

      confirm_invoice(live, "file_reuse", %{"invoice_date" => "2026-06-01"})

      entry = entry_for(review)
      assert entry.source_file_reuse_confirmed
      assert entry.date == ~D[2026-06-01]
    end

    test "another user's posting of the same bytes is never shown", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      other = user_fixture()
      _theirs = post_file_invoice(user_scope_fixture(other), other, @digest, @rent)
      review = pending_file_review(scope, user, @digest, @rent)

      {:ok, _live, html} = live(conn, invoice_path(review))

      refute html =~ "Same file already recorded"
      refute html =~ "Possible duplicate"
    end

    test "a soft match on a different file keeps the Post anyway flow", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      _original = post_file_invoice(scope, user, @digest, @rent)
      review = pending_file_review(scope, user, String.duplicate("0", 64), @rent)

      {:ok, live, html} = live(conn, invoice_path(review))

      assert html =~ "Possible duplicate"
      assert has_element?(live, ".duplicate-reason", "Same details")
      refute has_element?(live, "#confirm-file-reuse")

      confirm_invoice(live, "possible")
      refute Repo.get!(JournalEntry, entry_for(review).id).source_file_reuse_confirmed
    end
  end
end
