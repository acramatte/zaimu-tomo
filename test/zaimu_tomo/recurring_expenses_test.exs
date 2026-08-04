defmodule ZaimuTomo.RecurringExpensesTest do
  use ZaimuTomo.DataCase

  import Ecto.Changeset
  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.RecurringExpensesFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.JournalEntry
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.RecurringExpenses

  test "creates a scoped recurring expense with normalized currency and frequency" do
    scope = user_scope_fixture()

    assert {:ok, expense} =
             RecurringExpenses.create_recurring_expense(scope, %{
               name: "  Spotify family  ",
               amount_cents: 1_799,
               currency: " eur ",
               frequency: "monthly",
               start_date: ~D[2026-01-28]
             })

    assert expense.name == "Spotify family"
    assert expense.currency == "EUR"
    assert expense.frequency == :monthly
    assert expense.user_id == scope.user.id
  end

  test "rejects an end date before the start date" do
    scope = user_scope_fixture()

    assert {:error, changeset} =
             RecurringExpenses.create_recurring_expense(scope, %{
               name: "Rent",
               amount_cents: 118_000,
               currency: "EUR",
               frequency: :monthly,
               start_date: ~D[2026-01-15],
               end_date: ~D[2026-01-01]
             })

    assert {"must be on or after the start date", _} = changeset.errors[:end_date]
  end

  test "rejects a non-positive amount" do
    scope = user_scope_fixture()

    assert {:error, changeset} =
             RecurringExpenses.create_recurring_expense(scope, %{
               name: "Rent",
               amount_cents: 0,
               currency: "EUR",
               frequency: :monthly,
               start_date: ~D[2026-01-15]
             })

    assert {"must be greater than %{number}", _} = changeset.errors[:amount_cents]
  end

  test "scopes listing, lookups, updates, and deletes to the owning user" do
    scope = user_scope_fixture()
    other_scope = user_scope_fixture()
    expense = recurring_expense_fixture(scope, %{name: "Rent"})
    recurring_expense_fixture(other_scope, %{name: "Private gym"})

    assert [%{name: "Rent"}] = RecurringExpenses.list_recurring_expenses(scope)
    assert {:error, :not_found} = RecurringExpenses.get_recurring_expense(other_scope, expense.id)

    assert_raise MatchError, fn ->
      RecurringExpenses.update_recurring_expense(other_scope, expense, %{name: "Hijacked"})
    end

    assert_raise MatchError, fn ->
      RecurringExpenses.delete_recurring_expense(other_scope, expense)
    end
  end

  test "upcoming_occurrences returns the next occurrence per expense, sorted by date" do
    scope = user_scope_fixture()
    today = Date.utc_today()

    recurring_expense_fixture(scope, %{
      name: "Rent",
      start_date: today,
      amount_cents: 118_000
    })

    recurring_expense_fixture(scope, %{
      name: "Annual membership",
      frequency: :yearly,
      start_date: Date.add(today, -300),
      amount_cents: 56_000
    })

    assert [
             %{date: rent_date, expense: %{name: "Rent", amount_cents: 118_000}},
             %{expense: %{name: "Annual membership"}}
           ] = RecurringExpenses.upcoming_occurrences(scope)

    assert rent_date == today
  end

  test "upcoming_occurrences excludes ended expenses" do
    scope = user_scope_fixture()

    recurring_expense_fixture(scope, %{
      name: "Old gym",
      start_date: ~D[2026-01-01],
      end_date: Date.add(Date.utc_today(), -1)
    })

    assert RecurringExpenses.upcoming_occurrences(scope) == []
  end

  test "covered_occurrence_keys reflects linked journal entries per month" do
    scope = user_scope_fixture()
    expense = recurring_expense_fixture(scope)

    keys = RecurringExpenses.covered_occurrence_keys(scope)
    refute RecurringExpenses.covered_occurrence?(keys, expense, ~D[2026-01-20])

    {:ok, _} =
      RecurringExpenses.link_journal_entry(scope, expense, create_entry(scope, ~D[2026-01-15]))

    keys = RecurringExpenses.covered_occurrence_keys(scope)
    assert RecurringExpenses.covered_occurrence?(keys, expense, ~D[2026-01-20])
    refute RecurringExpenses.covered_occurrence?(keys, expense, ~D[2026-02-20])
  end

  test "candidate_entries finds same-amount unlinked entries around the due date" do
    scope = user_scope_fixture()
    other_scope = user_scope_fixture()

    expense = recurring_expense_fixture(scope, %{name: "Rent", start_date: ~D[2026-01-01]})
    due = ~D[2026-02-12]

    matching = create_entry(scope, ~D[2026-02-14])
    create_entry(scope, ~D[2026-01-20])
    create_entry(scope, ~D[2026-02-14], 99_000)
    create_entry(other_scope, ~D[2026-02-14])

    assert [%{id: id}] = RecurringExpenses.candidate_entries(scope, expense, due)
    assert id == matching.id
  end

  test "candidate_entries excludes entries already linked to an expense" do
    scope = user_scope_fixture()
    expense = recurring_expense_fixture(scope, %{name: "Rent", start_date: ~D[2026-01-01]})
    linked_expense = recurring_expense_fixture(scope, %{name: "Other rent"})
    entry = create_entry(scope, ~D[2026-02-14])

    {:ok, _} = RecurringExpenses.link_journal_entry(scope, linked_expense, entry)

    assert RecurringExpenses.candidate_entries(scope, expense, ~D[2026-02-12]) == []
  end

  test "links and unlinks a journal entry with ownership checks" do
    scope = user_scope_fixture()
    other_scope = user_scope_fixture()
    expense = recurring_expense_fixture(scope)
    entry = create_entry(scope, ~D[2026-01-15])
    other_entry = create_entry(other_scope, ~D[2026-01-15])

    assert_raise MatchError, fn ->
      RecurringExpenses.link_journal_entry(scope, expense, other_entry)
    end

    {:ok, linked} = RecurringExpenses.link_journal_entry(scope, expense, entry)
    assert linked.recurring_expense_id == expense.id
    assert [%{id: id}] = RecurringExpenses.linked_journal_entries(scope, expense)
    assert id == entry.id

    {:ok, unlinked} = RecurringExpenses.unlink_journal_entry(scope, entry)
    assert is_nil(unlinked.recurring_expense_id)
    assert RecurringExpenses.linked_journal_entries(scope, expense) == []
  end

  test "deleting an expense keeps its journal entries and clears the link" do
    scope = user_scope_fixture()
    expense = recurring_expense_fixture(scope)
    entry = create_entry(scope, ~D[2026-01-15])

    {:ok, _} = RecurringExpenses.link_journal_entry(scope, expense, entry)
    {:ok, _} = RecurringExpenses.delete_recurring_expense(scope, expense)

    reloaded = Repo.reload!(entry)
    assert is_nil(reloaded.recurring_expense_id)
    assert Repo.get(JournalEntry, entry.id).id == entry.id
  end

  defp create_entry(scope, date, amount_cents \\ 118_000) do
    document =
      Repo.insert!(%Document{
        filename: "invoice.pdf",
        filepath: "/tmp/invoice.pdf",
        user_id: scope.user.id
      })

    extracted_content = extracted_content_fixture(document, scope.user)
    decision = approved_review_fixture(extracted_content, scope.user)
    {:ok, entry} = Accounting.create_from_decision(decision)
    entry |> change(date: date, amount_cents: amount_cents) |> Repo.update!()
  end
end
