defmodule ZaimuTomo.RecurringExpensesFixtures do
  def recurring_expense_fixture(scope, attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        name: "Rent · Av. Louise",
        amount_cents: 118_000,
        currency: "EUR",
        frequency: :monthly,
        start_date: ~D[2026-01-01]
      })

    {:ok, expense} = ZaimuTomo.RecurringExpenses.create_recurring_expense(scope, attrs)
    expense
  end
end
