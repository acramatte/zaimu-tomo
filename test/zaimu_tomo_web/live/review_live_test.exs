defmodule ZaimuTomoWeb.ReviewLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review
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

  test "shows a successful Jev shadow check on the review page", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        analysis: %{
          "verification" => %{
            "status" => "verified",
            "reason" => "All fields match.",
            "typesafe_shadow" => %{
              "status" => "verified",
              "model" => "jev-1.13.0",
              "max_error_probability" => 0.07,
              "review_threshold" => 0.7,
              "field_probabilities" => %{
                "amount_to_pay_cents" => 0.07,
                "issuer" => 0.03
              }
            }
          }
        }
      })

    review = pending_review_fixture(extracted_content)
    {:ok, _show_live, html} = live(conn, ~p"/reviews/#{review}")

    refute html =~ "Verifier flagged this extraction"
    assert html =~ "Quality checks"
    assert html =~ "Independent check: Verified"
    assert html =~ "<details class=\"quality-check-details\""
    assert html =~ "<summary>View independent check</summary>"
    assert html =~ "class=\"pill verified\">Verified</span>"
    refute html =~ "class=\"pill posted\">Posted</span>"
    assert html =~ "jev-1.13.0"
    assert html =~ "0.07"
    assert html =~ "amount_to_pay_cents 0.07"
  end

  test "shows a Jev shadow warning without changing the authoritative review controls", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
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
              "field_probabilities" => %{
                "amount_to_pay_cents" => 0.91,
                "issuer" => 0.75
              }
            }
          }
        }
      })

    review = pending_review_fixture(extracted_content)
    {:ok, show_live, html} = live(conn, ~p"/reviews/#{review}")

    refute html =~ "Verifier flagged this extraction"
    assert html =~ "Independent check: Needs review"
    assert html =~ "class=\"pill review\""
    assert html =~ "amount_to_pay_cents,issuer"
    assert has_element?(show_live, "button", "Approve & post")
    assert has_element?(show_live, "button", "Reject")
  end

  test "shows a failed Jev shadow check without changing the verifier card", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    document = document_fixture(scope)

    extracted_content =
      extracted_content_fixture(document, user, %{
        analysis: %{
          "verification" => %{
            "status" => "verified",
            "reason" => "All fields match.",
            "typesafe_shadow" => %{
              "status" => "verification_failed",
              "error" => "invalid_response"
            }
          }
        }
      })

    review = pending_review_fixture(extracted_content)
    {:ok, _show_live, html} = live(conn, ~p"/reviews/#{review}")

    refute html =~ "Verifier flagged this extraction"
    assert html =~ "Quality checks"
    assert html =~ "Could not verify"
    assert html =~ "invalid_response"
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
      refute has_element?(show_live, "button", "Approve & post")

      # The plain approve event does not post a possible duplicate.
      render_click(show_live, "approve")
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"

      assert {:error, {:redirect, %{to: to}}} =
               show_live |> element("button", "Post anyway") |> render_click()

      assert to =~ "/journal_entries/"
    end

    test "treats a numbered entry matched by the unnumbered tuple as a possible duplicate", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      original_document = document_fixture(scope)

      original_content =
        extracted_content_fixture(original_document, user, %{extracted_data: @base_data})

      {:ok, _} = Review.create_initial_decision(original_content)
      {:ok, _} = Review.approve_invoice(original_content.id, user.id)

      content =
        extracted_content_fixture(document_fixture(scope), user, %{
          extracted_data: Map.merge(@base_data, %{invoice_number: nil})
        })

      review = pending_review_fixture(content)

      {:ok, show_live, html} = live(conn, ~p"/reviews/#{review}")

      assert html =~ "Possible duplicate"
      refute html =~ "Invoice already recorded"
      assert has_element?(show_live, "button", "Post anyway")
    end

    test "renders an unnumbered review with a missing amount", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      content =
        extracted_content_fixture(document_fixture(scope), user, %{
          extracted_data: Map.merge(@base_data, %{invoice_number: nil, amount_to_pay_cents: nil})
        })

      review = pending_review_fixture(content)

      assert {:ok, _show_live, html} = live(conn, ~p"/reviews/#{review}")
      refute html =~ "Possible duplicate"
    end

    test "amending into a possible duplicate posts only through Post anyway", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      unnumbered = Map.merge(@base_data, %{invoice_number: nil})

      original_content =
        extracted_content_fixture(document_fixture(scope), user, %{extracted_data: unnumbered})

      {:ok, _} = Review.create_initial_decision(original_content)
      {:ok, _} = Review.approve_invoice(original_content.id, user.id)

      content =
        extracted_content_fixture(document_fixture(scope), user, %{
          extracted_data: Map.merge(unnumbered, %{amount_to_pay_cents: 1})
        })

      review = pending_review_fixture(content)
      {:ok, edit_live, _html} = live(conn, ~p"/reviews/#{review}/edit")

      submit = fn amount ->
        edit_live
        |> form("#review_form", %{
          "review_decision" => %{"review_notes" => "Amended"},
          "decision_data" => %{
            "issuer" => "Acme Corp",
            "invoice_number" => "",
            "invoice_date" => "2026-06-09",
            "amount_to_pay_cents" => amount,
            "currency" => "CHF",
            "reason_for_payment" => "Amended data"
          }
        })
        |> render_submit()
      end

      assert submit.("4200") =~ "Possible duplicate"
      # Saving again re-checks and re-asks instead of posting.
      assert submit.("4200") =~ "Post anyway"
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"

      assert {:error, {:redirect, %{to: to}}} =
               edit_live |> element("button", "Post anyway") |> render_click()

      assert to =~ "/journal_entries/"
    end

    test "a non-integer amount in the amend form does not crash the duplicate check", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      content =
        extracted_content_fixture(document_fixture(scope), user, %{
          extracted_data: Map.merge(@base_data, %{invoice_number: nil})
        })

      review = pending_review_fixture(content)
      {:ok, edit_live, _html} = live(conn, ~p"/reviews/#{review}/edit")

      html =
        edit_live
        |> form("#review_form", %{
          "review_decision" => %{"review_notes" => "Amended"},
          "decision_data" => %{
            "issuer" => "Acme Corp",
            "invoice_number" => "",
            "invoice_date" => "2026-06-09",
            "amount_to_pay_cents" => "12.50",
            "currency" => "CHF",
            "reason_for_payment" => "Amended data"
          }
        })
        |> render_submit()

      assert is_binary(html)
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"
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

      {:ok, show_live, html} = live(conn, ~p"/reviews/#{review}")

      assert html =~ "Same file already recorded"
      assert html =~ "Reject this duplicate review."
      assert has_element?(show_live, ".duplicate-reason", "Same file")
      assert has_element?(show_live, ~s|a[href="/journal_entries/#{entry.id}"]|, "Open entry")
      refute has_element?(show_live, "button", "Approve & post")
      refute has_element?(show_live, "button", "Post anyway")
      refute has_element?(show_live, "#confirm-file-reuse")
      refute html =~ "This invoice number is already recorded"
      refute html =~ @digest

      # A crafted confirmation is refused by the view and the context alike.
      render_click(show_live, "approve", %{"confirm_file_reuse" => "true"})
      assert render(show_live) =~ "Reject this duplicate review."
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"
      assert Accounting.get_journal_entry_for_decision(review.id) == :error
    end

    test "asks to confirm a reuse when only the file matches, and posts after confirmation", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      original = post_file_invoice(scope, user, @digest, @rent)

      # A different OCR reading of the same bytes (scenario 1).
      review =
        pending_file_review(scope, user, @digest, %{
          @rent
          | issuer: "Landlord A.G.",
            amount_to_pay_cents: 15_000
        })

      {:ok, show_live, html} = live(conn, ~p"/reviews/#{review}")

      assert html =~ "Same file already recorded"
      assert html =~ "Is this a reused bill for a new period?"
      assert html =~ Calendar.strftime(original.inserted_at, "%Y-%m-%d")
      refute has_element?(show_live, "button", "Approve & post")
      refute has_element?(show_live, "button", "Post anyway")

      # The plain approve event does not post an exact-file match.
      render_click(show_live, "approve")
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"

      assert {:error, {:redirect, %{to: "/journal_entries/" <> id}}} =
               show_live |> element("#confirm-file-reuse") |> render_click()

      entry = Repo.get!(ZaimuTomo.Accounting.JournalEntry, String.to_integer(id))
      assert entry.source_file_reuse_confirmed
      assert entry.source_document_sha256 == @digest
    end

    test "a reused QR-bill becomes confirmable after amending the date", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      _original = post_file_invoice(scope, user, @digest, @rent)
      review = pending_file_review(scope, user, @digest, @rent)

      {:ok, edit_live, html} = live(conn, ~p"/reviews/#{review}/edit")
      assert html =~ "Same file already recorded"

      submit = fn date ->
        edit_live
        |> form("#review_form", %{
          "review_decision" => %{"review_notes" => "Next month"},
          "decision_data" => %{
            "issuer" => "Landlord AG",
            "invoice_number" => "",
            "invoice_date" => date,
            "amount_to_pay_cents" => "150000",
            "currency" => "CHF",
            "reason_for_payment" => "Rent"
          }
        })
        |> render_submit()
      end

      # Unchanged facts stay a hard block with reject guidance.
      html = submit.("2026-05-01")
      assert html =~ "Reject this duplicate review."
      refute has_element?(edit_live, "#confirm-file-reuse")
      render_click(edit_live, "confirm_file_reuse_save")
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"

      # The new period makes it a confirmable reuse; saving alone never posts.
      assert submit.("2026-06-01") =~ "Is this a reused bill for a new period?"
      assert Repo.get!(ReviewDecision, review.id).review_status == "pending"
      refute has_element?(edit_live, "button", "Post anyway")

      assert {:error, {:redirect, %{to: "/journal_entries/" <> id}}} =
               edit_live |> element("#confirm-file-reuse") |> render_click()

      entry = Repo.get!(ZaimuTomo.Accounting.JournalEntry, String.to_integer(id))
      assert entry.source_file_reuse_confirmed
      assert entry.date == ~D[2026-06-01]
    end

    test "another user's posting of the same bytes is never shown", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      other_user = user_fixture()
      _theirs = post_file_invoice(user_scope_fixture(other_user), other_user, @digest, @rent)
      review = pending_file_review(scope, user, @digest, @rent)

      {:ok, show_live, html} = live(conn, ~p"/reviews/#{review}")

      refute html =~ "Same file already recorded"
      refute html =~ "Possible duplicate"
      assert has_element?(show_live, "button", "Approve & post")
    end

    test "a soft match on a different file keeps the Post anyway flow", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      _original = post_file_invoice(scope, user, @digest, @rent)
      review = pending_file_review(scope, user, String.duplicate("0", 64), @rent)

      {:ok, show_live, html} = live(conn, ~p"/reviews/#{review}")

      assert html =~ "Possible duplicate"
      assert has_element?(show_live, ".duplicate-reason", "Same details")
      refute has_element?(show_live, "#confirm-file-reuse")

      assert {:error, {:redirect, %{to: "/journal_entries/" <> id}}} =
               show_live |> element("button", "Post anyway") |> render_click()

      refute Repo.get!(ZaimuTomo.Accounting.JournalEntry, String.to_integer(id)).source_file_reuse_confirmed
    end
  end
end
