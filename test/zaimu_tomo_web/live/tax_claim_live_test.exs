defmodule ZaimuTomoWeb.TaxClaimLiveTest do
  use ZaimuTomoWeb.ConnCase

  import Phoenix.LiveViewTest
  import ZaimuTomo.ReviewFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Accounting.TaxDeductionClaim
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  setup :register_and_log_in_user

  test "groups claims by the selected tax year and links to their workspaces", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    candidate = candidate_claim(scope, user)
    filed = candidate_claim(scope, user)
    prior_year = candidate_claim(scope, user)

    assert {:ok, _filed} =
             Accounting.review_tax_deduction_claim(scope, filed.id, %{
               "status" => "claimed",
               "tax_return_reference" => "2026 return — appendix 3"
             })

    prior_year |> Ecto.Changeset.change(tax_year: 2025) |> Repo.update!()

    {:ok, live, _html} = live(conn, "/tax_claims?tax_year=2026")

    assert has_element?(live, "#tax-claim-years a[href='/tax_claims?tax_year=2025']", "2025")
    assert has_element?(live, "#tax-claim-#{candidate.id}[href='/tax_claims/#{candidate.id}']")
    assert has_element?(live, "#tax-claim-#{filed.id}[href='/tax_claims/#{filed.id}']")
    refute has_element?(live, "#tax-claim-#{prior_year.id}")
    assert has_element?(live, "section", "To review")
    assert has_element?(live, "section", "Included in return")
  end

  test "records a candidate in a return from its dedicated workspace", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    claim = candidate_claim(scope, user)

    {:ok, live, _html} = live(conn, "/tax_claims/#{claim.id}")

    assert has_element?(live, "#tax-claim-file-form")
    assert has_element?(live, "#tax-claim-mark-not-deductible", "Mark not deductible")

    live
    |> form("#tax-claim-file-form", %{
      "filing" => %{"tax_return_reference" => "2026 return — appendix 3"}
    })
    |> render_submit()

    assert %TaxDeductionClaim{
             status: "claimed",
             tax_return_reference: "2026 return — appendix 3"
           } = Repo.get!(TaxDeductionClaim, claim.id)

    assert has_element?(live, "#tax-claim-return-reference", "2026 return — appendix 3")

    assert has_element?(
             live,
             "#tax-claim-record-authority-decision",
             "Record tax authority decision"
           )

    refute has_element?(live, "#tax-claim-authority-decision-form")
  end

  test "records an authority decision only after a claim is filed",
       %{
         conn: conn,
         scope: scope,
         user: user
       } do
    claim = candidate_claim(scope, user)

    assert {:ok, _filed} =
             Accounting.review_tax_deduction_claim(scope, claim.id, %{
               "status" => "claimed",
               "tax_return_reference" => "2026 return — appendix 3"
             })

    {:ok, live, _html} = live(conn, "/tax_claims/#{claim.id}")

    refute has_element?(live, "#tax-claim-authority-decision-form")

    live
    |> element("#tax-claim-record-authority-decision")
    |> render_click()

    assert has_element?(live, "#tax-claim-authority-decision-form")

    html =
      live
      |> form("#tax-claim-authority-decision-form", %{"authority" => %{}})
      |> render_submit()

    assert html =~ "can&#39;t be blank"

    live
    |> form("#tax-claim-authority-decision-form", %{
      "authority" => %{
        "authority_name" => "Zurich Tax Office",
        "authority_reference" => "Decision 2026-041"
      }
    })
    |> render_submit()

    assert %TaxDeductionClaim{status: "disallowed"} = Repo.get!(TaxDeductionClaim, claim.id)

    assert has_element?(
             live,
             "#tax-claim-authority-decision",
             "Zurich Tax Office · Decision 2026-041"
           )
  end

  test "records a filer's own decision not to claim a candidate", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    claim = candidate_claim(scope, user)

    {:ok, live, _html} = live(conn, "/tax_claims/#{claim.id}")

    live
    |> element("#tax-claim-mark-not-deductible")
    |> render_click()

    assert %TaxDeductionClaim{status: "not_deductible", deductible_amount_cents: 0} =
             Repo.get!(TaxDeductionClaim, claim.id)

    assert has_element?(live, "#tax-claim-not-deductible")
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
