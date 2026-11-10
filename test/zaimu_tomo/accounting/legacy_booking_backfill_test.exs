defmodule ZaimuTomo.Accounting.LegacyBookingBackfillTest do
  use ZaimuTomo.DataCase, async: true

  import ZaimuTomo.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]
  import ZaimuTomo.DocumentsFixtures
  import ZaimuTomo.ReviewFixtures, only: [extracted_content_fixture: 3]

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Accounting.LegacyBookingBackfill
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Review
  alias ZaimuTomo.Review.EventLog

  setup do
    user = user_fixture()
    %{user: user, scope: user_scope_fixture(user)}
  end

  test "a dry run reports the plan and changes nothing", %{scope: scope, user: user} do
    booked(scope, user, "Utility Co", "Utilities", "need")
    entry = legacy_entry(scope, user, "Utility Co")

    assert {:ok, summary} = LegacyBookingBackfill.run()

    assert [%{category: "Utilities", need_or_want: "need", precedent_count: 1}] = summary.matched
    assert summary.applied == []
    assert Repo.reload!(entry).status == "uncategorized"
    assert backfill_events() == []

    report = LegacyBookingBackfill.format_summary(summary)
    assert report =~ "dry run"
    assert report =~ "Would book entry #{entry.id} (Utility Co) as Utilities / need"
  end

  test "confirm books an uncategorized entry from a matching issuer and is repeatable", %{
    scope: scope,
    user: user
  } do
    booked(scope, user, "  UTILITY CO ", "Utilities", "need")
    booked(scope, user, "utility co", "Utilities", "need")
    entry = legacy_entry(scope, user, "Utility Co", notes: "Keep me")
    last_edit = ~U[2026-03-02 08:00:00Z]

    Repo.update_all(from(je in JournalEntry, where: je.id == ^entry.id),
      set: [updated_at: last_edit]
    )

    claims_before = Repo.aggregate(TaxDeductionClaim, :count)

    assert {:ok, summary} = LegacyBookingBackfill.run(confirm: true)
    assert [%{precedent_count: 2}] = summary.applied

    reloaded = Repo.reload!(entry)
    assert reloaded.category == "Utilities"
    assert reloaded.need_or_want == "need"
    assert reloaded.status == "posted"
    assert reloaded.notes == "Keep me"
    assert reloaded.updated_at == last_edit
    assert Repo.aggregate(TaxDeductionClaim, :count) == claims_before

    assert [event] = backfill_events()
    assert event.invoice_id == to_string(entry.id)
    assert event.user_id == user.id
    assert event.metadata["category"] == "Utilities"
    assert event.metadata["need_or_want"] == "need"
    assert event.metadata["tax_deduction_status"] == "undecided"
    assert event.metadata["previous_status"] == "uncategorized"
    assert event.metadata["previous_need_or_want"] == nil

    assert {:ok, again} = LegacyBookingBackfill.run(confirm: true)
    assert again.matched == []
    assert length(backfill_events()) == 1
  end

  test "a posted entry keeps its category when precedents only agree on need or want", %{
    scope: scope,
    user: user
  } do
    booked(scope, user, "Car Share Co", "Transportation", "want")
    booked(scope, user, "Car Share Co", "Holidays", "want")
    entry = legacy_entry(scope, user, "Car Share Co")

    Repo.update_all(from(je in JournalEntry, where: je.id == ^entry.id),
      set: [category: "Software", status: "posted"]
    )

    assert {:ok, %{applied: [_]}} = LegacyBookingBackfill.run(confirm: true)

    reloaded = Repo.reload!(entry)
    assert reloaded.category == "Software"
    assert reloaded.need_or_want == "want"
  end

  test "leaves entries unchanged without a single agreed precedent", %{scope: scope, user: user} do
    booked(scope, user, "Split", "Transportation", "want")
    booked(scope, user, "Split", "Transportation", "need")
    conflicting = legacy_entry(scope, user, "Split")
    no_history = legacy_entry(scope, user, "Never Seen")

    other = user_fixture()
    booked(user_scope_fixture(other), other, "Other Users Issuer", "Software", "want")
    other_users_issuer = legacy_entry(scope, user, "Other Users Issuer")

    assert {:ok, summary} = LegacyBookingBackfill.run(confirm: true)
    assert summary.applied == []

    reasons = Map.new(summary.unmatched, &{&1.entry.id, &1.reason})
    assert reasons[conflicting.id] == :conflicting_history
    assert reasons[no_history.id] == :no_history
    assert reasons[other_users_issuer.id] == :no_history

    assert Repo.reload!(conflicting).status == "uncategorized"

    assert LegacyBookingBackfill.format_summary(summary) =~
             "Book by hand: entry #{no_history.id} (Never Seen) at /documents/"
  end

  test "a manual decision books through normal posting with its tax treatment", %{
    scope: scope,
    user: user
  } do
    entry = legacy_entry(scope, user, " Course Provider ", notes: "Keep me")
    decision = %{category: "Education", need_or_want: "need", tax_status: "candidate"}

    assert {:ok, dry_run} =
             LegacyBookingBackfill.run(manual: %{{entry.id, "course provider"} => decision})

    assert Repo.reload!(entry).status == "uncategorized"

    assert LegacyBookingBackfill.format_summary(dry_run) =~
             "as Education / need from a manual decision, tax status candidate."

    assert {:ok, %{applied: [_], failed: []}} =
             LegacyBookingBackfill.run(
               confirm: true,
               manual: %{{entry.id, "course provider"} => decision}
             )

    reloaded = Repo.reload!(entry)
    assert reloaded.category == "Education"
    assert reloaded.need_or_want == "need"
    assert reloaded.status == "posted"
    assert reloaded.notes == "Keep me"

    claim = Repo.get_by!(TaxDeductionClaim, journal_entry_id: entry.id)
    assert claim.status == "candidate"
    assert claim.deductible_amount_cents == entry.amount_cents

    assert Repo.exists?(
             from e in EventLog,
               where:
                 e.event_type == "journal_entry_posted" and e.invoice_id == ^to_string(entry.id)
           )

    assert backfill_events() == []
  end

  test "a manual decision for another issuer does not apply", %{scope: scope, user: user} do
    entry = legacy_entry(scope, user, "Someone Else")
    decision = %{category: "Education", need_or_want: "need", tax_status: "candidate"}

    assert {:ok, summary} =
             LegacyBookingBackfill.run(
               confirm: true,
               manual: %{{entry.id, "course provider"} => decision}
             )

    assert summary.applied == []
    assert [%{reason: :no_history}] = summary.unmatched
    assert Repo.reload!(entry).status == "uncategorized"
  end

  defp backfill_events do
    Repo.all(
      from e in EventLog,
        where:
          e.event_type == "journal_entry_posted" and
            fragment("?->>'source'", e.metadata) == "legacy_booking_backfill"
    )
  end

  defp booked(scope, user, issuer, category, need_or_want) do
    {:ok, entry} =
      scope
      |> legacy_entry(user, issuer)
      |> Accounting.post_entry(user.id, category, need_or_want)

    entry
  end

  defp legacy_entry(scope, user, issuer, opts \\ []) do
    amount = System.unique_integer([:positive])
    document = document_fixture(scope, %{object_key: "documents/legacy-#{amount}.pdf"})

    content =
      extracted_content_fixture(document, user, %{
        extracted_data: %{
          amount_to_pay_cents: amount,
          invoice_date: "2026-03-01",
          invoice_number: nil,
          currency: "CHF",
          reason_for_payment: "Legacy",
          issuer: issuer
        }
      })

    {:ok, _} = Review.create_initial_decision(content)
    {:ok, decision} = Review.approve_invoice(content.id, user.id)
    {:ok, entry} = Accounting.get_journal_entry_for_decision(decision.id)

    Repo.update_all(from(je in JournalEntry, where: je.id == ^entry.id),
      set: [notes: Keyword.get(opts, :notes)]
    )

    Repo.get!(JournalEntry, entry.id)
  end
end
