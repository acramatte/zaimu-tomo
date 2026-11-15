defmodule ZaimuTomoWeb.StatementLiveTest do
  use ZaimuTomoWeb.ConnCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.FinancialAccountsFixtures
  import ZaimuTomo.StatementsFixtures

  alias ZaimuTomo.Repo
  alias ZaimuTomo.Statements
  alias ZaimuTomo.Statements.{ExtractJob, Statement}
  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    Memory.reset()
    on_exit(&Memory.reset/0)

    %{
      account:
        financial_account_fixture(scope, %{
          name: "Visa",
          account_type: :credit_card,
          currency: "CHF"
        })
    }
  end

  defp settle_jobs, do: Repo.delete_all(Oban.Job)

  describe "index" do
    test "lists statements by account with their status and period",
         %{conn: conn, scope: scope, account: account} do
      processing = statement_fixture(scope, account)
      ready = scope |> statement_fixture(account) |> put_extraction(%{currency: "CHF"})

      Repo.delete_all(
        from j in Oban.Job, where: fragment("?->>'statement_id'", j.args) == ^"#{ready.id}"
      )

      foreign_scope = user_scope_fixture()
      foreign = statement_fixture(foreign_scope, financial_account_fixture(foreign_scope))

      {:ok, view, _html} = live(conn, ~p"/statements")

      assert has_element?(view, "#statements-account-#{account.id} .card-title", "Visa")
      assert has_element?(view, "#statement-#{processing.id} .pill", "Processing")
      assert has_element?(view, "#statement-#{ready.id} .pill", "Read")
      assert has_element?(view, "#statement-#{ready.id}", "1 Oct 2026 – 31 Oct 2026")
      refute has_element?(view, "#statement-#{foreign.id}")
    end

    test "shows an empty state without statements", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/statements")
      assert has_element?(view, "#statements-empty")
    end

    test "the sidebar links to statements", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/statements")

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query(~s(a.nav-item.active[href="/statements"]))
             |> Enum.count() == 1
    end
  end

  describe "upload" do
    test "prefills the account from ?account= and uploads the file into a read job",
         %{conn: conn, scope: scope, account: account} do
      other = financial_account_fixture(scope, %{name: "Main", currency: "CHF"})

      {:ok, view, _html} = live(conn, ~p"/statements/new?account=#{account.id}")

      assert has_element?(
               view,
               ~s(#statement-form select option[value="#{account.id}"][selected])
             )

      refute has_element?(view, ~s(#statement-form select option[value="#{other.id}"][selected]))

      file =
        file_input(view, "#statement-form", :statement, [
          %{name: "october.pdf", content: "%PDF october", type: "application/pdf"}
        ])

      assert render_upload(file, "october.pdf") =~ "100%"

      assert {:error, {:live_redirect, %{to: "/statements/" <> id}}} =
               view
               |> form("#statement-form", statement: %{financial_account_id: account.id})
               |> render_submit()

      statement = Repo.get!(Statement, id)
      assert statement.financial_account_id == account.id
      assert statement.filename == "october.pdf"
      assert {:ok, "%PDF october"} = Storage.read_object(statement.object_key)
      assert_enqueued(worker: ExtractJob, args: %{statement_id: statement.id})
    end

    test "sends an already uploaded file to its statement",
         %{conn: conn, scope: scope, account: account} do
      existing = statement_fixture(scope, account, "%PDF same")

      {:ok, view, _html} = live(conn, ~p"/statements/new?account=#{account.id}")

      file =
        file_input(view, "#statement-form", :statement, [
          %{name: "again.pdf", content: "%PDF same", type: "application/pdf"}
        ])

      render_upload(file, "again.pdf")

      assert {:error, {:live_redirect, %{to: to, flash: _}}} =
               view
               |> form("#statement-form", statement: %{financial_account_id: account.id})
               |> render_submit()

      assert to == ~p"/statements/#{existing}"
      assert Repo.aggregate(Statement, :count) == 1
    end

    test "shows a refused upload's own reason, not the account prompt",
         %{conn: conn, account: account} do
      {:ok, view, _html} = live(conn, ~p"/statements/new?account=#{account.id}")

      file =
        file_input(view, "#statement-form", :statement, [
          %{name: " ", content: "%PDF october", type: "application/pdf"}
        ])

      render_upload(file, " ")

      html =
        view
        |> form("#statement-form", statement: %{financial_account_id: account.id})
        |> render_submit()

      assert html =~ "Filename can&#39;t be blank."
      refute html =~ "Choose one of your accounts."
      assert Repo.aggregate(Statement, :count) == 0
    end

    test "asks for an account first when the user has none", %{conn: conn} do
      conn = log_in_user(conn, ZaimuTomo.AccountsFixtures.user_fixture())
      {:ok, view, _html} = live(conn, ~p"/statements/new")

      assert has_element?(view, "#statement-upload-no-accounts")
      refute has_element?(view, "#statement-form")
    end
  end

  describe "show" do
    test "renders the header, the balance badge, and the lines",
         %{conn: conn, scope: scope, account: account} do
      statement =
        scope
        |> statement_fixture(account)
        |> put_extraction(%{currency: "CHF", opening_balance_cents: -10_000}, [
          {~D[2026-10-03], "SBB CFF FFS", -4_200},
          {~D[2026-10-10], "Payment, thank you", 10_000}
        ])

      settle_jobs()

      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")

      assert has_element?(view, "h1", "October 2026 statement")
      assert has_element?(view, "#statement-status .pill", "Read")
      assert has_element?(view, "#statement-balances", "CHF −100.00")
      assert has_element?(view, "#statement-balances", "CHF −42.00")
      assert has_element?(view, "#statement-balance .pill", "Balanced")
      assert has_element?(view, "#statement-line-1", "SBB CFF FFS")
      assert has_element?(view, "#statement-line-1", "CHF −42.00")
      assert has_element?(view, "#statement-line-2", "CHF 100.00")
      refute has_element?(view, "#statement-retry")
    end

    test "shows how far an unbalanced read is off and reads it again",
         %{conn: conn, scope: scope, account: account} do
      statement =
        scope
        |> statement_fixture(account)
        |> put_extraction(%{currency: "CHF", closing_balance_cents: 99_000}, [
          {~D[2026-10-03], "Coffee", -500}
        ])

      settle_jobs()

      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")

      assert has_element?(view, "#statement-balance .pill", "Off by CHF 5.00")

      view |> element("#statement-retry") |> render_click()

      assert_enqueued(worker: ExtractJob, args: %{statement_id: statement.id})
      assert has_element?(view, "#statement-status .pill", "Processing")
      refute has_element?(view, "#statement-retry")
      assert render(view) =~ "Reading the statement again."
    end

    test "explains a failed read and keeps the earlier lines",
         %{conn: conn, scope: scope, account: account} do
      statement =
        scope
        |> statement_fixture(account)
        |> put_extraction(%{currency: "CHF", failure_code: "currency_mismatch"}, [
          {~D[2026-10-03], "Coffee", -500}
        ])

      settle_jobs()

      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")

      assert has_element?(view, "#statement-status .pill", "Failed")

      assert has_element?(
               view,
               "#statement-failure",
               "its currency is not the account's currency"
             )

      assert has_element?(view, "#statement-failure", "from the earlier read")
      assert has_element?(view, "#statement-line-1", "Coffee")
      assert has_element?(view, "#statement-retry")
    end

    test "words a processing failure the way the invoice pages do",
         %{conn: conn, scope: scope, account: account} do
      statement =
        scope
        |> statement_fixture(account)
        |> put_extraction(%{currency: "CHF", failure_code: "llm_request_failed:http_429"})

      settle_jobs()

      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")

      assert has_element?(view, "#statement-failure", "the extraction service was rate-limited")
    end

    test "updates when the read finishes in the background",
         %{conn: conn, scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")
      assert has_element?(view, "#statement-status .pill", "Processing")

      settle_jobs()
      read = put_extraction(statement, %{currency: "CHF"}, [{~D[2026-10-03], "Coffee", -500}])
      Statements.broadcast_updated(read)

      assert render(view) =~ "Coffee"
      assert has_element?(view, "#statement-status .pill", "Read")
    end

    test "deletes the statement and returns to the list",
         %{conn: conn, scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")

      assert {:error, {:live_redirect, %{to: "/statements"}}} =
               view |> element("#statement-delete") |> render_click()

      refute Repo.get(Statement, statement.id)
      assert {:error, :not_found} = Storage.read_object(statement.object_key)
    end

    test "a statement deleted elsewhere sends the open page back to the list",
         %{conn: conn, scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")

      Repo.delete!(statement)
      send(view.pid, {:statement_updated, statement.id})

      assert {"/statements", %{"info" => "This statement was deleted."}} = assert_redirect(view)
    end

    test "a foreign or missing statement is not found", %{conn: conn} do
      foreign_scope = user_scope_fixture()
      foreign = statement_fixture(foreign_scope, financial_account_fixture(foreign_scope))

      for id <- [foreign.id, -1] do
        assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/statements/#{id}") end
      end
    end
  end

  test "the account page links to its statements and to an upload for it",
       %{conn: conn, account: account} do
    {:ok, view, _html} = live(conn, ~p"/accounts/#{account}")

    assert has_element?(
             view,
             ~s(#account-statements-link[href="/statements#statements-account-#{account.id}"])
           )

    assert has_element?(
             view,
             ~s(#account-upload-statement-link[href="/statements/new?account=#{account.id}"])
           )
  end
end
