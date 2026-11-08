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

    test "revises the tax treatment of a posted entry", %{conn: conn, scope: scope, user: user} do
      entry = create_entry(scope, user)

      {:ok, _entry} =
        Accounting.post_entry(entry, user.id, "Software", "need", nil, %{"status" => "candidate"})

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      assert has_element?(live, "#tax-revision-form-status option[value=claimed]")
      assert has_element?(live, "#tax-revision-form-status option[value=disallowed]")
      assert has_element?(live, "#tax-revision-form-amount[value='42.00']")

      live
      |> form("#tax-revision-form", %{
        "tax_revision" => %{
          "status" => "claimed",
          "deductible_amount" => "12.50",
          "reason" => "Half business use"
        }
      })
      |> render_submit()

      assert has_element?(live, "#journal-entry-tax-treatment", "Included in tax return")
      assert has_element?(live, "#journal-entry-deductible-amount", "EUR 12.50")
      assert has_element?(live, "#journal-entry-tax-reason", "Half business use")

      live
      |> form("#tax-revision-form", %{
        "tax_revision" => %{
          "status" => "disallowed",
          "deductible_amount" => "12.50",
          "reason" => "Tax office: private expense"
        }
      })
      |> render_submit()

      assert has_element?(live, "#journal-entry-tax-treatment", "Not allowed")
      assert has_element?(live, "#journal-entry-deductible-amount", "EUR 0.00")

      {:ok, updated} = Accounting.get_journal_entry(entry.id, user.id)
      assert updated.tax_deduction_claim.status == "disallowed"
      assert updated.tax_deduction_claim.notes == "Tax office: private expense"
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
      |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "claimed"}})
      |> render_submit()

      {:ok, revised} = Accounting.get_journal_entry(entry.id, user.id)
      assert revised.tax_deduction_claim.status == "claimed"
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
          "tax_revision" => %{"status" => "claimed", "reason" => String.duplicate("a", 256)}
        })
        |> render_submit()

      assert html =~ "should be at most 255 character(s)"

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{
            "status" => "claimed",
            "reason" => "",
            "deductible_amount" => "21474836.48"
          }
        })
        |> render_submit()

      assert html =~ "must be less than or equal to 2147483647"

      for amount <- ["NaN", "Infinity", "1e5", "1.234"] do
        html =
          live
          |> form("#tax-revision-form", %{
            "tax_revision" => %{"status" => "claimed", "deductible_amount" => amount}
          })
          |> render_submit()

        assert html =~ "must be an amount with up to 2 decimals"
      end

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{"status" => "claimed", "deductible_amount" => "-1"}
        })
        |> render_submit()

      assert html =~ "must be greater than or equal to 0"

      {:ok, unchanged} = Accounting.get_journal_entry(entry.id, user.id)
      assert unchanged.tax_deduction_claim.status == "undecided"
    end

    test "revises a credit note with its negative amount", %{conn: conn, scope: scope, user: user} do
      entry = create_entry(scope, user)

      Repo.update_all(from(je in JournalEntry, where: je.id == ^entry.id),
        set: [amount_cents: -5000]
      )

      {:ok, _entry} = Accounting.post_entry(Repo.reload!(entry), user.id, "Software", "need")

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      live
      |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "claimed"}})
      |> render_submit()

      {:ok, revised} = Accounting.get_journal_entry(entry.id, user.id)
      assert revised.tax_deduction_claim.status == "claimed"
      assert revised.tax_deduction_claim.deductible_amount_cents == -5000

      html =
        live
        |> form("#tax-revision-form", %{
          "tax_revision" => %{"status" => "claimed", "deductible_amount" => "10.00"}
        })
        |> render_submit()

      assert html =~ "must be 0 or negative for a credit note"
    end

    test "revises an entry that has no tax claim yet", %{conn: conn, scope: scope, user: user} do
      entry = create_entry(scope, user)
      {:ok, _entry} = Accounting.post_entry(entry, user.id, "Software", "need")

      Repo.delete_all(
        from c in ZaimuTomo.Accounting.TaxDeductionClaim, where: c.journal_entry_id == ^entry.id
      )

      {:ok, live, _html} = live(conn, ~p"/journal_entries/#{entry}")

      live
      |> form("#tax-revision-form", %{"tax_revision" => %{"status" => "claimed"}})
      |> render_submit()

      assert has_element?(live, "#journal-entry-tax-treatment", "Included in tax return")
    end

    test "lists need or want classification on the index", %{conn: conn, scope: scope, user: user} do
      entry = create_entry(scope, user)
      {:ok, _entry} = Accounting.post_entry(entry, user.id, "Subscriptions", "want")

      {:ok, _live, html} = live(conn, ~p"/journal_entries")

      assert html =~ "Subscriptions"
      assert html =~ "Want"
      assert html =~ "EUR 42.00"
      refute html =~ "€42.00"
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
    test "orders the feed newest-first by last activity", %{conn: conn, scope: scope, user: user} do
      e1 = create_entry(scope, user)
      e2 = create_entry(scope, user)
      e3 = create_entry(scope, user)

      base = ~U[2026-06-01 00:00:00Z]
      set_timestamps(e1, inserted_at: base, updated_at: ~U[2026-06-01 10:00:00Z])
      set_timestamps(e2, inserted_at: base, updated_at: ~U[2026-06-02 10:00:00Z])
      set_timestamps(e3, inserted_at: base, updated_at: ~U[2026-06-03 10:00:00Z])

      {:ok, _live, html} = live(conn, ~p"/journal_entries")

      ids =
        Regex.scan(~r/id="entries-(\d+)"/, html)
        |> Enum.map(fn [_full, id] -> id end)

      assert ids == [Integer.to_string(e3.id), Integer.to_string(e2.id), Integer.to_string(e1.id)]
    end
  end

  defp create_entry(scope, user) do
    document =
      Repo.insert!(%Document{
        filename: "invoice.pdf",
        object_key: "documents/invoice.pdf",
        user_id: scope.user.id
      })

    extracted_content = extracted_content_fixture(document, user)
    decision = approved_review_fixture(extracted_content, user)
    # Approving posts the journal entry transactionally in the review context.
    {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)
    entry
  end

  defp set_timestamps(entry, opts) do
    from(je in JournalEntry, where: je.id == ^entry.id)
    |> Repo.update_all(set: opts)
  end
end
