defmodule ZaimuTomo.AccountingTest do
  use ZaimuTomo.DataCase

  import Ecto.Query, warn: false
  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounts
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo
  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.EventLog

  describe "post_entry/6" do
    test "posts an entry with need or want classification" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      entry = create_entry(scope, user)

      assert {:ok, updated} =
               Accounting.post_entry(entry, user.id, "Utilities", "need", "Minimum living cost")

      assert updated.status == "posted"
      assert updated.category == "Utilities"
      assert updated.need_or_want == "need"
      assert updated.notes == "Minimum living cost"

      assert %EventLog{metadata: %{"category" => "Utilities", "need_or_want" => "need"}} =
               Repo.get_by(EventLog,
                 event_type: "journal_entry_posted",
                 invoice_id: to_string(entry.id),
                 user_id: user.id
               )
    end

    test "rejects posting without need or want classification" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      entry = create_entry(scope, user)

      assert {:error, changeset} = Accounting.post_entry(entry, user.id, "Utilities", nil)
      assert %{need_or_want: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects unsupported need or want values" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      entry = create_entry(scope, user)

      assert {:error, changeset} = Accounting.post_entry(entry, user.id, "Utilities", "maybe")
      assert %{need_or_want: ["is invalid"]} = errors_on(changeset)
    end

    test "records a tax deduction claim separately from the journal entry" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      entry = create_entry(scope, user)

      assert {:ok, updated} =
               Accounting.post_entry(entry, user.id, "Software", "need", nil, %{
                 "status" => "candidate"
               })

      assert updated.tax_deduction_claim.status == "candidate"
      assert updated.tax_deduction_claim.tax_year == 2026
      assert updated.tax_deduction_claim.deductible_amount_cents == entry.amount_cents

      assert %EventLog{metadata: %{"tax_deduction_status" => "candidate"}} =
               Repo.get_by(EventLog,
                 event_type: "journal_entry_posted",
                 invoice_id: to_string(entry.id),
                 user_id: user.id
               )
    end

    test "database prevents deletion of a journal entry with its tax deduction claim" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      entry = create_entry(scope, user)

      assert {:error, changeset} =
               entry
               |> Ecto.Changeset.change()
               |> Ecto.Changeset.foreign_key_constraint(:id,
                 name: :tax_deduction_claims_journal_entry_id_fkey,
                 message: "cannot be deleted while its tax deduction claim exists"
               )
               |> Repo.delete()

      assert %{id: ["cannot be deleted while its tax deduction claim exists"]} =
               errors_on(changeset)

      assert %JournalEntry{id: journal_entry_id} = Repo.get(JournalEntry, entry.id)
      assert journal_entry_id == entry.id
    end

    test "sets the deductible amount to zero for an entry marked not deductible" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      entry = create_entry(scope, user)

      assert {:ok, updated} =
               Accounting.post_entry(entry, user.id, "Software", "need", nil, %{
                 status: "not_deductible"
               })

      assert updated.tax_deduction_claim.status == "not_deductible"
      assert updated.tax_deduction_claim.deductible_amount_cents == 0
    end
  end

  describe "monthly_spending/2" do
    test "aggregates posted entries by normalized category for the scoped user" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      other_scope = user_scope_fixture()

      create_entry(scope, user, ~D[2026-06-01], 1_200, "EUR", " groceries ")
      create_entry(scope, user, ~D[2026-06-30], 800, "USD", "GROCERIES")
      create_entry(scope, user, ~D[2026-06-15], 2_500, "CHF", "Software")
      create_entry(scope, user, ~D[2026-05-31], 9_999, "CHF", "Previous month")
      create_entry(other_scope, other_scope.user, ~D[2026-06-15], 7_500, "CHF", "Other user")

      assert %{
               month_start: ~D[2026-06-01],
               currency: "CHF",
               total_cents: 4_500,
               entry_count: 3,
               categories: [
                 %{category: "Software", total_cents: 2_500, entry_count: 1},
                 %{category: "Groceries", total_cents: 2_000, entry_count: 2}
               ]
             } = Accounting.monthly_spending(scope, ~D[2026-06-08])
    end

    test "excludes entries that have not been categorized and posted" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      create_entry(scope, user, ~D[2026-06-08], 1_200, "CHF", nil)

      assert %{
               total_cents: 0,
               entry_count: 0,
               categories: []
             } = Accounting.monthly_spending(scope, ~D[2026-06-08])
    end

    test "displays spending in the user's base currency when set" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      create_entry(scope, user, ~D[2026-06-01], 1_200, "EUR", "Groceries")

      {:ok, user} = Accounts.update_user_profile(user, %{base_currency: "JPY"})
      scope = user_scope_fixture(user)

      assert %{currency: "JPY"} = Accounting.monthly_spending(scope, ~D[2026-06-08])
    end

    test "excludes successful uploaded extractions awaiting review until they become journal entries" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)

      extracted_content =
        extracted_content_fixture(document, user, %{
          extracted_data: %{
            amount_to_pay_cents: 3_333,
            invoice_date: "2026-06-09",
            invoice_number: "INV-JUNE",
            currency: "CHF",
            reason_for_payment: "June invoice",
            issuer: "June Vendor"
          }
        })

      pending_review_fixture(extracted_content)

      assert %{
               total_cents: 0,
               entry_count: 0,
               categories: []
             } = Accounting.monthly_spending(scope, ~D[2026-06-09])
    end

    test "does not count a categorized journal entry as an uncategorized pending extraction" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)

      extracted_content =
        extracted_content_fixture(document, user, %{
          extracted_data: %{
            amount_to_pay_cents: 4_444,
            invoice_date: "2026-06-09",
            invoice_number: "INV-SOFTWARE",
            currency: "CHF",
            reason_for_payment: "Software subscription",
            issuer: "Software Vendor"
          }
        })

      decision = pending_review_fixture(extracted_content)
      {:ok, entry} = Accounting.create_from_decision(decision)
      {:ok, _entry} = Accounting.post_entry(entry, user.id, "Software", "need")

      assert %{
               total_cents: 4_444,
               entry_count: 1,
               categories: [
                 %{category: "Software", total_cents: 4_444, entry_count: 1}
               ]
             } = Accounting.monthly_spending(scope, ~D[2026-06-09])
    end

    test "does not create a journal entry when extracted invoice date is not ISO formatted" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      document = document_fixture(scope)

      extracted_content =
        extracted_content_fixture(document, user, %{
          extracted_data: %{
            amount_to_pay_cents: 2_162,
            invoice_date: "Jun 5~Jul 5, 2026",
            invoice_number: "FD2JAIMF-0002",
            currency: "USD",
            reason_for_payment: "Claude Pro Jun 5~Jul 5, 2026 subscription fee",
            issuer: "Anthropic, PBC"
          }
        })

      decision = pending_review_fixture(extracted_content)

      assert {:error, changeset} = Accounting.create_from_decision(decision)
      assert %{date: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_journal_entries/1" do
    test "sorts entries with newer updated_at above older ones" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      e1 = create_entry(scope, user)
      e2 = create_entry(scope, user)
      e3 = create_entry(scope, user)

      base = ~U[2026-06-01 12:00:00Z]
      set_timestamps(e1, inserted_at: base, updated_at: ~U[2026-06-01 13:00:00Z])
      set_timestamps(e2, inserted_at: base, updated_at: ~U[2026-06-02 13:00:00Z])
      set_timestamps(e3, inserted_at: base, updated_at: ~U[2026-06-03 13:00:00Z])

      assert Accounting.list_journal_entries(user.id) |> Enum.map(& &1.id) ==
               [e3.id, e2.id, e1.id]
    end

    test "sorts by inserted_at descending when updated_at has not advanced" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      e1 = create_entry(scope, user)
      e2 = create_entry(scope, user)

      # updated_at is NOT NULL (Ecto timestamps), so an entry never edited has
      # updated_at == inserted_at; ordering then falls back to created_at (inserted_at).
      set_timestamps(e1,
        inserted_at: ~U[2026-06-01 12:00:00Z],
        updated_at: ~U[2026-06-01 12:00:00Z]
      )

      set_timestamps(e2,
        inserted_at: ~U[2026-06-02 12:00:00Z],
        updated_at: ~U[2026-06-02 12:00:00Z]
      )

      assert Accounting.list_journal_entries(user.id) |> Enum.map(& &1.id) == [e2.id, e1.id]
    end

    test "breaks ties with id descending when timestamps match" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      e1 = create_entry(scope, user)
      e2 = create_entry(scope, user)
      e3 = create_entry(scope, user)

      ts = ~U[2026-06-01 12:00:00Z]
      set_timestamps(e1, inserted_at: ts, updated_at: ts)
      set_timestamps(e2, inserted_at: ts, updated_at: ts)
      set_timestamps(e3, inserted_at: ts, updated_at: ts)

      assert Accounting.list_journal_entries(user.id) |> Enum.map(& &1.id) ==
               [e3.id, e2.id, e1.id]
    end

    test "returns correct ordered slices when paginating" do
      user = user_fixture()
      scope = user_scope_fixture(user)

      entries = for _ <- 1..5, do: create_entry(scope, user)

      Enum.with_index(entries, 1)
      |> Enum.each(fn {entry, i} ->
        set_timestamps(entry, updated_at: DateTime.add(~U[2026-06-01 00:00:00Z], i, :day))
      end)

      full = Accounting.list_journal_entries(user.id) |> Enum.map(& &1.id)

      page =
        from(je in JournalEntry,
          where: je.user_id == ^user.id,
          order_by: [
            desc: je.updated_at,
            desc: je.id
          ],
          limit: 2,
          offset: 1
        )
        |> Repo.all()
        |> Enum.map(& &1.id)

      assert page == Enum.slice(full, 1, 2)
    end
  end

  describe "duplicate_candidates/2" do
    test "finds a numbered match case-insensitively regardless of whitespace" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      entry = create_entry(scope, user, invoice_number: "  INV-777  ", issuer: "Acme Corp")
      _other = create_entry(scope, user, invoice_number: "INV-888", issuer: "Acme Corp")

      data = %ExtractedData{
        issuer: " acme corp ",
        invoice_number: "inv-777",
        invoice_date: "2026-06-09",
        amount_to_pay_cents: 42_00,
        currency: "CHF"
      }

      assert [%JournalEntry{id: id}] = Accounting.duplicate_candidates(user.id, data)
      assert id == entry.id
      assert Accounting.strong_candidate?(Accounting.duplicate_candidates(user.id, data))
    end

    test "never crosses the user boundary" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      _entry = create_entry(scope, user, invoice_number: "INV-777", issuer: "Acme Corp")

      other_user = user_fixture()
      other_scope = user_scope_fixture(other_user)

      _other_entry =
        create_entry(other_scope, other_user, invoice_number: "INV-777", issuer: "Acme Corp")

      data = %ExtractedData{
        issuer: "Acme Corp",
        invoice_number: "INV-777",
        invoice_date: "2026-06-09",
        amount_to_pay_cents: 42_00,
        currency: "CHF"
      }

      assert [%JournalEntry{}] = Accounting.duplicate_candidates(user.id, data)
      assert [%JournalEntry{}] = Accounting.duplicate_candidates(other_user.id, data)
    end

    test "soft-matches unnumbered invoices only on the exact tuple" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      _entry = create_entry(scope, user)

      data = %ExtractedData{
        issuer: "Acme Corp",
        invoice_number: nil,
        invoice_date: "2026-06-09",
        amount_to_pay_cents: 42_00,
        currency: "CHF"
      }

      assert [%JournalEntry{}] = Accounting.duplicate_candidates(user.id, data)

      assert [] =
               Accounting.duplicate_candidates(user.id, %{
                 data
                 | amount_to_pay_cents: 43_00
               })

      assert [] =
               Accounting.duplicate_candidates(user.id, %{
                 data
                 | invoice_date: "2026-06-10"
               })
    end

    test "treats a whitespace-only number as missing and soft-matches" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      _entry = create_entry(scope, user, invoice_number: nil)

      data = %ExtractedData{
        issuer: "Acme Corp",
        invoice_number: "   ",
        invoice_date: "2026-06-09",
        amount_to_pay_cents: 42_00,
        currency: "CHF"
      }

      assert [%JournalEntry{}] = Accounting.duplicate_candidates(user.id, data)
    end

    test "does not soft-match with a non-ISO date or missing currency" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      _entry = create_entry(scope, user)

      data = %ExtractedData{
        issuer: "Acme Corp",
        invoice_number: nil,
        invoice_date: "Jun 9, 2026",
        amount_to_pay_cents: 42_00,
        currency: "CHF"
      }

      assert [] = Accounting.duplicate_candidates(user.id, data)

      assert [] =
               Accounting.duplicate_candidates(user.id, %{
                 data
                 | invoice_date: "2026-06-09",
                   currency: nil
               })
    end

    test "the database blocks a second numbered entry for the same issuer" do
      user = user_fixture()
      scope = user_scope_fixture(user)
      _entry = create_entry(scope, user, invoice_number: "INV-777", issuer: "Acme Corp")

      document = document_fixture(scope)

      extracted_content =
        extracted_content_fixture(document, user, %{
          extracted_data: %{
            amount_to_pay_cents: 42_00,
            invoice_date: "2026-06-09",
            invoice_number: "INV-777",
            currency: "CHF",
            reason_for_payment: "Same invoice again",
            issuer: "Acme Corp"
          }
        })

      {:ok, _} = Review.create_initial_decision(extracted_content)

      assert {:error, :duplicate_invoice} =
               Review.approve_invoice(extracted_content.id, user.id)
    end
  end

  defp create_entry(scope, user, overrides \\ []) do
    document = document_fixture(scope)

    extracted_data =
      %{
        amount_to_pay_cents: 42_00,
        invoice_date: "2026-06-09",
        invoice_number: "INV-" <> String.slice(Ecto.UUID.generate(), 0, 8),
        currency: "CHF",
        reason_for_payment: "Office supplies",
        issuer: "Acme Corp"
      }
      |> Map.merge(Map.new(overrides))

    extracted_content =
      extracted_content_fixture(document, user, %{extracted_data: extracted_data})

    decision = approved_review_fixture(extracted_content, user)

    # Approving posts the journal entry transactionally in the review context.
    {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)
    entry
  end

  defp create_entry(scope, user, date, amount_cents, currency, category) do
    entry = create_entry(scope, user)

    entry =
      entry
      |> Ecto.Changeset.change(date: date, amount_cents: amount_cents, currency: currency)
      |> Repo.update!()

    if category do
      {:ok, entry} = Accounting.post_entry(entry, user.id, category, "need")
      entry
    else
      entry
    end
  end

  defp document_fixture(scope) do
    Repo.insert!(%Document{
      filename: "invoice.pdf",
      object_key: "documents/invoice.pdf",
      user_id: scope.user.id
    })
  end

  defp set_timestamps(entry, opts) do
    from(je in JournalEntry, where: je.id == ^entry.id)
    |> Repo.update_all(set: opts)
  end
end
