defmodule ZaimuTomo.Repo.Migrations.AddTaxClaimLifecycleReferences do
  use Ecto.Migration

  def change do
    alter table(:tax_deduction_claims) do
      add :tax_return_reference, :string
      add :authority_name, :string
      add :authority_reference, :string
    end

    # Revisions made before these columns existed could set claimed or
    # disallowed without references; mark those as not recorded so the checks
    # hold and the gap stays visible.
    execute(
      """
      UPDATE tax_deduction_claims SET tax_return_reference = 'not recorded'
      WHERE status IN ('claimed', 'disallowed')
      """,
      ""
    )

    execute(
      """
      UPDATE tax_deduction_claims
      SET authority_name = 'not recorded', authority_reference = 'not recorded'
      WHERE status = 'disallowed'
      """,
      ""
    )

    create constraint(:tax_deduction_claims, :tax_deduction_claims_claimed_return_reference_check,
             check: "status <> 'claimed' OR btrim(coalesce(tax_return_reference, '')) <> ''"
           )

    create constraint(:tax_deduction_claims, :tax_deduction_claims_disallowed_authority_check,
             check:
               "status <> 'disallowed' OR (btrim(coalesce(authority_name, '')) <> '' AND btrim(coalesce(authority_reference, '')) <> '')"
           )
  end
end
