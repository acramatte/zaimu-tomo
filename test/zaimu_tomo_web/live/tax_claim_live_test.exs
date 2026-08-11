defmodule ZaimuTomoWeb.TaxClaimLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  setup :register_and_log_in_user

  test "lists candidate claims and records their tax-return resolution", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    claim = candidate_claim(scope, user)

    {:ok, live, _html} = live(conn, "/tax_claims")

    assert has_element?(live, "#tax-claim-#{claim.id}")
    assert has_element?(live, "#tax-claim-resolution-form-#{claim.id}")
    assert has_element?(live, "#tax-claim-#{claim.id}", "Potentially deductible")

    live
    |> form("#tax-claim-resolution-form-#{claim.id}", %{
      "claim_id" => claim.id,
      "resolution" => %{
        "status" => "claimed",
        "tax_return_reference" => "2026 return — appendix 3"
      }
    })
    |> render_submit()

    assert %TaxDeductionClaim{
             status: "claimed",
             tax_return_reference: "2026 return — appendix 3"
           } = Repo.get!(TaxDeductionClaim, claim.id)

    refute has_element?(live, "#tax-claim-#{claim.id}")
  end

  test "keeps the candidate visible and displays validation errors for missing resolution context",
       %{
         conn: conn,
         scope: scope,
         user: user
       } do
    claim = candidate_claim(scope, user)

    {:ok, live, _html} = live(conn, "/tax_claims")

    html =
      live
      |> form("#tax-claim-resolution-form-#{claim.id}", %{
        "claim_id" => claim.id,
        "resolution" => %{"status" => "disallowed"}
      })
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert has_element?(live, "#tax-claim-#{claim.id}")
  end

  defp candidate_claim(scope, user) do
    document =
      Repo.insert!(%Document{
        filename: "invoice.pdf",
        filepath: "/tmp/invoice.pdf",
        user_id: scope.user.id
      })

    extracted_content = extracted_content_fixture(document, user)
    decision = approved_review_fixture(extracted_content, user)
    {:ok, entry} = Accounting.create_from_decision(decision)

    assert {:ok, posted} =
             Accounting.post_entry(entry, user.id, "Software", "need", nil, %{
               "status" => "candidate"
             })

    posted.tax_deduction_claim
  end
end
