defmodule ZaimuTomoWeb.JournalEntryLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  setup :register_and_log_in_user

  describe "Show" do
    test "sends an unbooked entry to its invoice page instead of booking here", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry = create_entry(scope, user)

      decision =
        ZaimuTomo.Review.ReviewDecision
        |> Repo.get!(entry.review_decision_id)
        |> Repo.preload(:extracted_content)

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      path = ~p"/documents/#{decision.extracted_content.document_id}"
      assert has_element?(live, ~s(#book-on-invoice-page[href="#{path}"]))
      refute has_element?(live, "form")
    end

    test "shows the tax treatment linked to a posted entry", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry = create_entry(scope, user)

      {:ok, _entry} =
        Accounting.post_entry(entry, user.id, "Software", "need", nil, %{"status" => "candidate"})

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      refute has_element?(live, "#book-on-invoice-page")
      assert has_element?(live, "#journal-entry-tax-treatment", "Tax treatment")
      assert has_element?(live, "#journal-entry-tax-treatment", "Potentially deductible")
    end

    test "revises the tax treatment through its lifecycle", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry = create_entry(scope, user)

      {:ok, _entry} =
        Accounting.post_entry(entry, user.id, "Software", "need", nil, %{"status" => "candidate"})

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      assert has_element?(live, "#tax-revision-form-status option[value=claimed]")
      refute has_element?(live, "#tax-revision-form-status option[value=disallowed]")
      assert has_element?(live, "#tax-revision-form-amount[value='42.00']")
      refute has_element?(live, "#tax-revision-form-return-reference")

      live
      |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "claimed"}})
      |> render_change()

      assert has_element?(live, "#tax-revision-form-return-reference")
      refute has_element?(live, "#tax-revision-form-authority-name")

      html =
        live
        |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "claimed"}})
        |> render_submit()

      assert html =~ "can&#39;t be blank"

      live
      |> form("#tax-revision-form", %{
        "tax_revision" => %{
          "status" => "claimed",
          "deductible_amount" => "12.50",
          "reason" => "Half business use",
          "tax_return_reference" => "2026 return"
        }
      })
      |> render_submit()

      assert has_element?(live, "#journal-entry-tax-treatment", "Included in tax return")
      assert has_element?(live, "#journal-entry-deductible-amount", "EUR 12.50")
      assert has_element?(live, "#journal-entry-tax-return-reference", "2026 return")
      assert has_element?(live, "#flash-info", "Tax treatment revised")
      assert has_element?(live, "#tax-revision-form-amount[type=text][inputmode=decimal]")
      assert has_element?(live, "#journal-entry-tax-reason", "Half business use")

      live
      |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "disallowed"}})
      |> render_change()

      live
      |> form("#tax-revision-form", %{
        "tax_revision" => %{
          "status" => "disallowed",
          "reason" => "Tax office: private expense",
          "authority_name" => "Steueramt Zürich",
          "authority_reference" => "A-77"
        }
      })
      |> render_submit()

      assert has_element?(live, "#journal-entry-tax-treatment", "Not allowed")
      assert has_element?(live, "#journal-entry-deductible-amount", "EUR 0.00")
      assert has_element?(live, "#journal-entry-tax-return-reference", "2026 return")
      assert has_element?(live, "#journal-entry-tax-authority", "Steueramt Zürich (A-77)")
      refute has_element?(live, "#tax-revision-form-status option[value=candidate]")

      live
      |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "claimed"}})
      |> render_change()

      assert has_element?(live, "label", "Reason (required for a correction)")

      # A real submit carries the pre-filled refusal reason, which can't
      # double as the reason for the correction.
      assert has_element?(live, "#tax-revision-form-reason", "Tax office: private expense")

      html =
        live
        |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "claimed"}})
        |> render_submit()

      assert html =~ "must explain the correction, not repeat the last reason"
      assert has_element?(live, "#journal-entry-tax-treatment", "Not allowed")

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{"status" => "claimed", "reason" => ""}
        })
        |> render_submit()

      assert html =~ "is required to correct a filed or refused claim"

      live
      |> form("#tax-revision-form", %{
        "tax_revision" => %{"status" => "claimed", "reason" => "Appeal upheld"}
      })
      |> render_submit()

      assert has_element?(live, "#journal-entry-tax-treatment", "Included in tax return")
      refute has_element?(live, "#journal-entry-tax-authority")

      {:ok, updated} = Accounting.get_journal_entry(entry.id, user.id)
      assert updated.tax_deduction_claim.status == "claimed"
      assert updated.tax_deduction_claim.tax_return_reference == "2026 return"
      assert updated.tax_deduction_claim.notes == "Appeal upheld"
    end

    test "rejects an invalid revision amount and keeps the claim", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry = create_entry(scope, user)

      {:ok, _entry} =
        Accounting.post_entry(entry, user.id, "Software", "need", nil, %{"status" => "candidate"})

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{"status" => "claimed", "deductible_amount" => "12.345"}
        })
        |> render_submit()

      assert html =~ "must be an amount with up to 2 decimals"
      assert has_element?(live, "#tax-revision-form-amount[value='12.345']")
      assert has_element?(live, "#journal-entry-tax-treatment", "Potentially deductible")

      {:ok, unchanged} = Accounting.get_journal_entry(entry.id, user.id)
      assert unchanged.tax_deduction_claim.status == "candidate"
      assert unchanged.tax_deduction_claim.deductible_amount_cents == 42_00
    end

    test "a deductible status after one that deducts nothing defaults to the entry amount", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry = create_entry(scope, user)

      {:ok, _entry} =
        Accounting.post_entry(entry, user.id, "Software", "need", nil, %{
          "status" => "not_deductible"
        })

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      live
      |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "candidate"}})
      |> render_submit()

      {:ok, revised} = Accounting.get_journal_entry(entry.id, user.id)
      assert revised.tax_deduction_claim.status == "candidate"
      assert revised.tax_deduction_claim.deductible_amount_cents == 42_00
    end

    test "shows an inline error for a reason or amount too large to store", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry = create_entry(scope, user)
      {:ok, _entry} = Accounting.post_entry(entry, user.id, "Software", "need")

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{"status" => "candidate", "reason" => String.duplicate("a", 256)}
        })
        |> render_submit()

      assert html =~ "should be at most 255 character(s)"

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{
            "status" => "candidate",
            "reason" => "",
            "deductible_amount" => "21474836.48"
          }
        })
        |> render_submit()

      assert html =~ "must be an amount with up to 2 decimals"
      refute html =~ "2147483647"

      for amount <- ["NaN", "Infinity", "1e5", "1.234"] do
        html =
          live
          |> form("#tax-revision-form", %{
            "tax_revision" => %{"status" => "candidate", "deductible_amount" => amount}
          })
          |> render_submit()

        assert html =~ "must be an amount with up to 2 decimals"
      end

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{"status" => "candidate", "deductible_amount" => "-1"}
        })
        |> render_submit()

      assert html =~ "must be between 0 and the invoice amount"

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{"status" => "candidate", "deductible_amount" => "42.01"}
        })
        |> render_submit()

      assert html =~ "must be between 0 and the invoice amount"

      {:ok, unchanged} = Accounting.get_journal_entry(entry.id, user.id)
      assert unchanged.tax_deduction_claim.status == "undecided"
    end

    test "a status that deducts nothing ignores the amount field", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry = create_entry(scope, user)
      {:ok, _entry} = Accounting.post_entry(entry, user.id, "Software", "need")

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      live
      |> form("#tax-revision-form", %{
        "tax_revision" => %{"status" => "not_deductible", "deductible_amount" => "12,50"}
      })
      |> render_submit()

      assert has_element?(live, "#journal-entry-tax-treatment", "Not deductible")
      assert has_element?(live, "#journal-entry-deductible-amount", "EUR 0.00")
    end

    test "revises a credit note with its negative amount", %{conn: conn, scope: scope, user: user} do
      entry = create_entry(scope, user)

      Repo.update_all(from(je in JournalEntry, where: je.id == ^entry.id),
        set: [amount_cents: -5000]
      )

      {:ok, _entry} = Accounting.post_entry(Repo.reload!(entry), user.id, "Software", "need")

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      live
      |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "candidate"}})
      |> render_submit()

      {:ok, revised} = Accounting.get_journal_entry(entry.id, user.id)
      assert revised.tax_deduction_claim.status == "candidate"
      assert revised.tax_deduction_claim.deductible_amount_cents == -5000

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{"status" => "candidate", "deductible_amount" => "10.00"}
        })
        |> render_submit()

      assert html =~ "must be between the credit note amount and 0"

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{"status" => "candidate", "deductible_amount" => "-50.01"}
        })
        |> render_submit()

      assert html =~ "must be between the credit note amount and 0"
    end

    test "revises an entry that has no tax claim yet", %{conn: conn, scope: scope, user: user} do
      entry = create_entry(scope, user)
      {:ok, _entry} = Accounting.post_entry(entry, user.id, "Software", "need")

      Repo.delete_all(
        from c in ZaimuTomo.Accounting.TaxDeductionClaim, where: c.journal_entry_id == ^entry.id
      )

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      live
      |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "candidate"}})
      |> render_submit()

      assert has_element?(live, "#journal-entry-tax-treatment", "Potentially deductible")
    end

    test "displays the invoice amount with the journal entry currency", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      entry =
        create_entry(scope, user)
        |> Ecto.Changeset.change(amount_cents: 12_345, currency: "USD")
        |> Repo.update!()

      {:ok, _live, html} = live(conn, ~p"/journal_entries/#{entry}")

      assert html =~ "USD 123.45"
      refute html =~ "€123.45"
    end
  end

  describe "Index" do
    test "queues unbooked entries above a ledger of posted entries grouped by month", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      unbooked = create_entry(scope, user)
      june = posted_entry(scope, user, ~D[2026-06-09], 4200, "EUR", "Subscriptions", "want")
      june_chf = posted_entry(scope, user, ~D[2026-06-20], 1050, "CHF", "Groceries", "need")

      {:ok, live, _html} = live(conn, ~p"/journal_entries")

      assert has_element?(live, "#booking-queue #entry-#{unbooked.id}", "Needs booking")
      refute has_element?(live, "#ledger #entry-#{unbooked.id}")

      assert has_element?(live, "#month-2026-06-01", "June 2026")
      assert has_element?(live, "#month-2026-06-01", "CHF 10.50 · EUR 42.00")
      assert has_element?(live, "#month-2026-06-01 #entry-#{june.id}", "Subscriptions")
      assert has_element?(live, "#month-2026-06-01 #entry-#{june.id}", "Want")
      assert has_element?(live, "#month-2026-06-01 #entry-#{june_chf.id}", "CHF 10.50")
    end

    test "loads earlier months on demand and switches year", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      for month <- 1..5, do: posted_entry(scope, user, Date.new!(2026, month, 3), 100, "CHF")
      old = posted_entry(scope, user, ~D[2025-04-03], 100, "CHF")

      {:ok, live, _html} = live(conn, ~p"/journal_entries")

      assert has_element?(live, "#month-2026-05-01")
      assert has_element?(live, "#month-2026-03-01")
      refute has_element?(live, "#month-2026-02-01")
      assert has_element?(live, "#ledger", "3 of 5 entries")

      live |> element("#ledger-load-more", "Load Jan – Feb 2026") |> render_click()

      assert has_element?(live, "#month-2026-01-01")
      refute has_element?(live, "#ledger-load-more")
      assert has_element?(live, "#ledger", "All of 2026 shown")

      live |> form("#ledger-year", %{"year" => "2025"}) |> render_change()

      assert_patch(live, ~p"/journal_entries?year=2025")
      assert has_element?(live, "#month-2025-04-01 #entry-#{old.id}")
      refute has_element?(live, "#month-2026-05-01")
    end

    test "expands a row into its details and links an unbooked one to its invoice", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      unbooked = create_entry(scope, user)
      posted = posted_entry(scope, user, ~D[2026-06-09], 4200, "EUR", "Software")

      {:ok, live, _html} = live(conn, ~p"/journal_entries")

      refute has_element?(live, "#entry-#{posted.id}-detail")
      live |> element("#entry-#{posted.id} .ledger-row") |> render_click()
      assert has_element?(live, "#entry-#{posted.id}-detail", "Potentially deductible")
      assert has_element?(live, "#entry-#{posted.id}-detail", "Software · Need")

      live |> element("#entry-#{unbooked.id} .ledger-row") |> render_click()
      refute has_element?(live, "#entry-#{posted.id}-detail")

      decision =
        ZaimuTomo.Review.ReviewDecision
        |> Repo.get!(unbooked.review_decision_id)
        |> Repo.preload(:extracted_content)

      path = ~p"/documents/#{decision.extracted_content.document_id}?from=journal"
      assert has_element?(live, ~s(#entry-#{unbooked.id}-book[href="#{path}"]))

      live |> element("#entry-#{unbooked.id} .ledger-row") |> render_click()
      refute has_element?(live, "#entry-#{unbooked.id}-detail")

      # The invoice page opened from the queue leads back to the journal.
      {:ok, invoice, _html} = live(conn, path)
      assert has_element?(invoice, ~s(#invoice-back-to-journal[href="/journal_entries"]))
      refute has_element?(invoice, "a", "← Documents")
    end

    test "filters to the booking queue or to tax candidates", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      unbooked = create_entry(scope, user)
      candidate = posted_entry(scope, user, ~D[2026-06-09], 4200, "EUR")

      not_deductible =
        posted_entry(
          scope,
          user,
          ~D[2026-06-10],
          1000,
          "EUR",
          "Software",
          "need",
          "not_deductible"
        )

      {:ok, live, _html} = live(conn, ~p"/journal_entries")

      assert has_element?(live, "#ledger-filters a", "All 3")
      assert has_element?(live, "#ledger-filters a", "Not booked 1")
      assert has_element?(live, "#ledger-filters a", "Tax candidates 1")

      live |> element("#ledger-filters a", "Not booked") |> render_click()
      assert_patch(live, ~p"/journal_entries?filter=not_booked&year=2026")
      assert has_element?(live, "#booking-queue #entry-#{unbooked.id}")
      refute has_element?(live, "#ledger")

      live |> element("#ledger-filters a", "Tax candidates") |> render_click()
      refute has_element?(live, "#booking-queue")
      assert has_element?(live, "#month-2026-06-01 #entry-#{candidate.id}")
      refute has_element?(live, "#entry-#{not_deductible.id}")
      assert has_element?(live, "#month-2026-06-01", "EUR 42.00")
    end
  end

  defp posted_entry(
         scope,
         user,
         date,
         cents,
         currency,
         category \\ "Software",
         nw \\ "need",
         tax_status \\ "candidate"
       ) do
    entry =
      create_entry(scope, user, %{
        extracted_data: %{
          amount_to_pay_cents: cents,
          invoice_date: Date.to_iso8601(date),
          currency: currency,
          issuer: "Issuer #{System.unique_integer([:positive])}"
        }
      })
      |> Ecto.Changeset.change(date: date, amount_cents: cents, currency: currency)
      |> Repo.update!()

    {:ok, entry} =
      Accounting.post_entry(entry, user.id, category, nw, nil, %{"status" => tax_status})

    entry
  end

  defp create_entry(scope, user, extraction_attrs \\ %{}) do
    document =
      Repo.insert!(%Document{
        filename: "invoice.pdf",
        object_key: "documents/invoice.pdf",
        user_id: scope.user.id
      })

    extracted_content = extracted_content_fixture(document, user, extraction_attrs)
    decision = approved_review_fixture(extracted_content, user)
    # Approving posts the journal entry transactionally in the review context.
    {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)
    entry
  end
end
