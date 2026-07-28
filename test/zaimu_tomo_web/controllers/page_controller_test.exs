defmodule ZaimuTomoWeb.PageControllerTest do
  use ZaimuTomoWeb.ConnCase

  import ZaimuTomo.ReviewFixtures
  import ZaimuTomo.FinancialAccountsFixtures

  alias ZaimuTomo.Accounting
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  setup :register_and_log_in_user

  test "GET / renders current-month spending for the authenticated user", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    today = Date.utc_today()

    entry = create_entry(scope, user)

    entry
    |> Ecto.Changeset.change(date: today, amount_cents: 12_345, currency: "USD")
    |> Repo.update!()
    |> Accounting.post_entry(user.id, "Software", "need")

    previous_entry = create_entry(scope, user)

    previous_entry
    |> Ecto.Changeset.change(
      date: today |> Date.beginning_of_month() |> Date.add(-1),
      amount_cents: 10_000,
      currency: "CHF"
    )
    |> Repo.update!()
    |> Accounting.post_entry(user.id, "Software", "need")

    previous_only_entry = create_entry(scope, user)

    previous_only_entry
    |> Ecto.Changeset.change(
      date: today |> Date.beginning_of_month() |> Date.add(-1),
      amount_cents: 5_000,
      currency: "CHF"
    )
    |> Repo.update!()
    |> Accounting.post_entry(user.id, "Transportation", "need")

    conn = get(conn, ~p"/")
    document = conn |> html_response(200) |> LazyHTML.from_document()
    html = LazyHTML.to_html(document)

    assert has_element?(document, ".spending-period-summary")
    assert html =~ "#{Calendar.strftime(today, "%B")} spending"

    assert html =~
             "Compared with #{Calendar.strftime(Date.add(Date.beginning_of_month(today), -1), "%B")}"

    assert has_element?(document, "#spending-categories")
    assert has_element?(document, ".spending-row-labels")
    assert html =~ "Change"

    assert has_element?(
             document,
             "[data-category='Software'][data-total-cents='12345'][data-previous-total-cents='10000'][data-delta-cents='2345']"
           )

    assert has_element?(
             document,
             "[data-category='Transportation'][data-total-cents='0'][data-previous-total-cents='5000'][data-delta-cents='-5000']"
           )

    assert has_element?(document, "#spending-chart")
    assert has_element?(document, "#spending-chart [data-category='Transportation']")
  end

  test "GET / renders an empty spending state", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert has_element?(document, "#spending-empty")
    assert has_element?(document, "#spending-chart-empty")
  end

  test "GET / renders the latest savings account balance in its source currency", %{
    conn: conn,
    scope: scope
  } do
    account =
      financial_account_fixture(scope, %{
        name: "Emergency fund",
        currency: "USD",
        amount_cents: 12_345
      })

    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    html = LazyHTML.to_html(document)

    assert has_element?(document, "#dashboard-savings-#{account.id}")
    assert html =~ "USD 123.45"
    assert html =~ "Emergency fund"
  end

  test "GET / renders the latest cash account balance in its source currency", %{
    conn: conn,
    scope: scope
  } do
    account =
      financial_account_fixture(scope, %{
        name: "Travel wallet",
        account_type: :cash,
        currency: "CHF",
        amount_cents: 9_876
      })

    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    html = LazyHTML.to_html(document)

    assert has_element?(document, "#dashboard-cash-#{account.id}")
    assert html =~ "CHF 98.76"
    assert html =~ "Travel wallet"
  end

  test "GET / renders the latest investment account balance in its source currency", %{
    conn: conn,
    scope: scope
  } do
    account =
      financial_account_fixture(scope, %{
        name: "Brokerage",
        account_type: :investment,
        currency: "USD",
        amount_cents: 12_345
      })

    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    html = LazyHTML.to_html(document)

    assert has_element?(document, "#dashboard-investments-#{account.id}")
    assert html =~ "USD 123.45"
    assert html =~ "Brokerage"
  end

  test "GET / renders a zero-total state instead of a donut for offsetting entries", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    today = Date.utc_today()

    for {amount_cents, category} <- [{5_000, "Software"}, {-5_000, "Refund"}] do
      entry = create_entry(scope, user)

      entry
      |> Ecto.Changeset.change(date: today, amount_cents: amount_cents, currency: "CHF")
      |> Repo.update!()
      |> Accounting.post_entry(user.id, category, "need")
    end

    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert has_element?(document, "#spending-categories")
    assert has_element?(document, "#spending-chart-zero-total")
    refute has_element?(document, "#spending-chart")
  end

  test "GET / groups categories beyond the visible limit into Other for both spending views", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    today = Date.utc_today()

    Enum.each(1..7, fn index ->
      entry = create_entry(scope, user)

      entry
      |> Ecto.Changeset.change(
        date: today,
        amount_cents: index * 100,
        currency: "CHF"
      )
      |> Repo.update!()
      |> Accounting.post_entry(user.id, "Category #{index}", "need")
    end)

    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert has_element?(
             document,
             "#spending-categories [data-category='Other'][data-total-cents='300']"
           )

    assert has_element?(document, "#spending-chart [data-category='Other']")
    refute has_element?(document, "[data-category='Category 1']")
  end

  defp create_entry(scope, user) do
    document =
      Repo.insert!(%Document{
        filename: "invoice.pdf",
        filepath: "/tmp/invoice.pdf",
        user_id: scope.user.id
      })

    extracted_content = extracted_content_fixture(document, user)
    decision = approved_review_fixture(extracted_content, user)
    {:ok, entry} = Accounting.create_from_decision(decision)
    entry
  end

  defp has_element?(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> LazyHTML.to_html()
    |> Kernel.!=("")
  end
end
