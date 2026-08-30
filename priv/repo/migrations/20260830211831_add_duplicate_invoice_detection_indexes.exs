defmodule ZaimuTomo.Repo.Migrations.AddDuplicateInvoiceDetectionIndexes do
  use Ecto.Migration

  @doc """
  Enforces one journal entry per (user, issuer, invoice number) at the
  database level and speeds up the unnumbered soft-match lookup.

  The unique index is partial because a missing or blank invoice number is
  not an identity: those candidates are surfaced as warnings instead.
  """
  def change do
    create unique_index(:journal_entries, [:user_id, :issuer, :invoice_number],
             where: "btrim(invoice_number) <> ''",
             name: :journal_entries_user_issuer_number_unique_index
           )

    create index(
             :journal_entries,
             [
               :user_id,
               "lower(btrim(issuer))",
               :date,
               :amount_cents,
               "lower(btrim(currency))"
             ],
             name: :journal_entries_unnumbered_invoice_lookup_index
           )
  end
end
