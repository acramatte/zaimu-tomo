defmodule ZaimuTomo.Repo.Migrations.AddTaxClaimLifecycleContext do
  use Ecto.Migration

  def change do
    alter table(:tax_deduction_claims) do
      add :tax_return_reference, :string
      add :authority_name, :string
      add :authority_reference, :string
    end

    create constraint(:tax_deduction_claims, :tax_deduction_claims_claimed_return_reference_check,
             check: "status <> 'claimed' OR btrim(coalesce(tax_return_reference, '')) <> ''"
           )

    create constraint(
             :tax_deduction_claims,
             :tax_deduction_claims_disallowed_authority_context_check,
             check:
               "status <> 'disallowed' OR (btrim(coalesce(authority_name, '')) <> '' AND btrim(coalesce(authority_reference, '')) <> '')"
           )
  end
end
