defmodule ZaimuTomo.Repo.Migrations.SetBaseCurrencyDefault do
  use Ecto.Migration

  def change do
    # Rows created before the column default existed hold NULL; stamp them
    # with the base-currency default so the column can become NOT NULL.
    # New registrations pick up the same default from the column.
    execute("UPDATE users SET base_currency = 'CHF' WHERE base_currency IS NULL", "")

    alter table(:users) do
      modify :base_currency, :string, null: false, default: "CHF"
    end
  end
end
