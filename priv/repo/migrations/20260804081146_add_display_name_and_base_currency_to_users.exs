defmodule ZaimuTomo.Repo.Migrations.AddDisplayNameAndBaseCurrencyToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # display_name is unset until the user picks one. base_currency is
      # nullable initially and takes the CHF column default (see
      # set_base_currency_default), which backfills existing rows and makes
      # the column NOT NULL.
      add :display_name, :string
      add :base_currency, :string
    end
  end
end
