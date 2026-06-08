defmodule ZaimuTomo.AccountingTest do
  use ZaimuTomo.DataCase

  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

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
      {:ok, _entry} = Accounting.post_entry(entry, user.id, "Software")

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

  defp create_entry(scope, user, date, amount_cents, currency, category) do
    document = document_fixture(scope)
    extracted_content = extracted_content_fixture(document, user)
    decision = approved_review_fixture(extracted_content, user)
    {:ok, entry} = Accounting.create_from_decision(decision)

    entry =
      entry
      |> Ecto.Changeset.change(date: date, amount_cents: amount_cents, currency: currency)
      |> Repo.update!()

    if category do
      {:ok, entry} = Accounting.post_entry(entry, user.id, category)
      entry
    else
      entry
    end
  end

  defp document_fixture(scope) do
    Repo.insert!(%Document{
      filename: "invoice.pdf",
      filepath: "/tmp/invoice.pdf",
      user_id: scope.user.id
    })
  end
end
