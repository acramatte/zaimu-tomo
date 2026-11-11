defmodule ZaimuTomo.Repo.Migrations.AddReviewDecisionChecks do
  use Ecto.Migration

  def change do
    # Rejections recorded before the reason was required have none; mark those
    # as not recorded so the check holds and the gap stays visible.
    execute(
      """
      UPDATE review_decisions SET rejection_reason = 'not recorded'
      WHERE review_status = 'rejected' AND btrim(coalesce(rejection_reason, '')) = ''
      """,
      ""
    )

    create constraint(:review_decisions, :review_decisions_review_status_check,
             check: "review_status IN ('pending', 'approved', 'amended', 'rejected', 'failed')"
           )

    create constraint(:review_decisions, :review_decisions_rejected_reason_check,
             check: "review_status <> 'rejected' OR btrim(coalesce(rejection_reason, '')) <> ''"
           )
  end
end
