defmodule ZaimuTomoWeb.StatementLiveTest do
  use ZaimuTomoWeb.ConnCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.FinancialAccountsFixtures
  import ZaimuTomo.ReviewFixtures, only: [journal_entry_fixture: 2]
  import ZaimuTomo.StatementsFixtures

  alias ZaimuTomo.FinancialAccounts
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

  defp await(view, selector, text, attempts \\ 40) do
    cond do
      has_element?(view, selector, text) -> :ok
      attempts == 0 -> flunk("expected #{selector} with #{text}, got: #{render(view)}")
      true -> Process.sleep(25) && await(view, selector, text, attempts - 1)
    end
  end

  test "unauthenticated requests redirect to log in" do
    for path <- [~p"/statements", ~p"/statements/new", ~p"/statements/1"] do
      conn = get(Phoenix.ConnTest.build_conn(), path)
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

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

    test "canceling the upload clears queued files when reopening upload",
         %{conn: conn, account: account} do
      {:ok, view, _html} = live(conn, ~p"/statements/new?account=#{account.id}")

      file =
        file_input(view, "#statement-form", :statement, [
          %{name: "queued.pdf", content: "%PDF queued", type: "application/pdf"}
        ])

      assert render_upload(file, "queued.pdf") =~ "queued.pdf"
      assert has_element?(view, ".statement-upload-entry", "queued.pdf")

      view |> element("#statement-upload a", "Cancel") |> render_click()
      refute has_element?(view, "#statement-upload")

      view |> element(".view-title-row a", "Upload statement") |> render_click()
      assert has_element?(view, "#statement-upload")
      refute has_element?(view, ".statement-upload-entry")
    end

    test "a rejected file disables submit and refuses to save", %{conn: conn, account: account} do
      {:ok, view, _html} = live(conn, ~p"/statements/new?account=#{account.id}")

      file =
        file_input(view, "#statement-form", :statement, [
          %{name: "notes.txt", content: "not a statement", type: "text/plain"}
        ])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(file, "notes.txt")

      assert has_element?(
               view,
               ".statement-upload-error",
               "Upload a PDF or an image of the statement."
             )

      assert has_element?(view, ~s(#statement-form button[type="submit"][disabled]))

      html =
        view
        |> form("#statement-form", statement: %{financial_account_id: account.id})
        |> render_submit()

      assert html =~ "Fix the file error before uploading."
      assert Repo.aggregate(Statement, :count) == 0
    end

    test "ignores malformed validate and save events without crashing",
         %{conn: conn, account: account} do
      {:ok, view, _html} = live(conn, ~p"/statements/new?account=#{account.id}")

      assert render_change(view, "validate", %{}) =~ "Upload a statement"
      assert render_submit(view, "save", %{}) =~ "Choose one of your accounts."
      assert Repo.aggregate(Statement, :count) == 0
    end

    test "adds a newly created account to the dropdown live via PubSub",
         %{conn: conn, scope: scope, account: account} do
      {:ok, view, _html} = live(conn, ~p"/statements/new?account=#{account.id}")

      {:ok, %{account: created}} =
        FinancialAccounts.create_financial_account_with_balance(
          scope,
          %{name: "Checking", account_type: :current, currency: "CHF"},
          %{amount_cents: 50_000, recorded_on: ~D[2026-10-01]}
        )

      assert render(view) =~ "Checking"

      assert has_element?(
               view,
               ~s(#statement-form select option[value="#{created.id}"]),
               "Checking · Current account · CHF"
             )

      assert has_element?(
               view,
               ~s(#statement-form select option[value="#{account.id}"][selected])
             )
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

    test "re-reads while processing until the read settles, without a broadcast",
         %{conn: conn, scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")
      assert has_element?(view, "#statement-status .pill", "Processing")

      put_extraction(statement, %{currency: "CHF"}, [{~D[2026-10-03], "Coffee", -500}])
      settle_jobs()

      await(view, "#statement-status .pill", "Read")
      assert has_element?(view, "#statement-line-1", "Coffee")
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

    test "shows absolute gap for negative balance differences and singularizes one line",
         %{conn: conn, scope: scope, account: account} do
      statement =
        scope
        |> statement_fixture(account)
        |> put_extraction(%{currency: "CHF", closing_balance_cents: 100_000}, [
          {~D[2026-10-03], "Coffee", -500}
        ])

      settle_jobs()

      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")

      assert has_element?(view, "#statement-balance .pill", "Off by CHF 5.00")
      refute has_element?(view, "#statement-balance .pill", "−")
      assert has_element?(view, "#statement-totals .card-meta", "1 line")
      refute has_element?(view, "#statement-totals .card-meta", "1 lines")
    end

    test "shows dashes for money out and money in before extraction",
         %{conn: conn, scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")

      totals =
        view
        |> element("#statement-totals")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".detail-row .num")
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert totals == ["—", "—"]
      refute has_element?(view, "#statement-totals", "CHF 0.00")
    end

    test "a foreign or missing statement is not found", %{conn: conn} do
      foreign_scope = user_scope_fixture()
      foreign = statement_fixture(foreign_scope, financial_account_fixture(foreign_scope))

      for id <- [foreign.id, -1, "not-an-id"] do
        assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/statements/#{id}") end
      end
    end
  end

  describe "backing" do
    defp posted_entry(scope, issuer, cents, date) do
      journal_entry_fixture(scope, %{
        issuer: issuer,
        amount_to_pay_cents: cents,
        currency: "CHF",
        invoice_date: date
      })
    end

    defp read_october(scope, account, lines) do
      statement =
        scope |> statement_fixture(account) |> put_extraction(%{currency: "CHF"}, lines)

      settle_jobs()
      statement
    end

    test "shows the entry backing each line, the coverage, and filters by tab",
         %{conn: conn, scope: scope, account: account} do
      statement =
        read_october(scope, account, [
          {~D[2026-10-03], "ACME CORP ZURICH", -4_200},
          {~D[2026-10-05], "CARD 1234 SHOP", -1_500},
          {~D[2026-10-06], "Parking", -700},
          {~D[2026-10-10], "Payment, thank you", 10_000}
        ])

      acme = posted_entry(scope, "ACME Corp", 4_200, "2026-10-01")
      bakery = posted_entry(scope, "Bakery Muller", 1_500, "2026-09-20")

      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}")

      assert has_element?(
               view,
               ~s(#statement-line-1 .backing.named a[href="/journal_entries/#{acme.id}"]),
               "ACME Corp · 01.10.2026"
             )

      assert has_element?(
               view,
               ~s(#statement-line-2 .backing.check a[href="/journal_entries/#{bakery.id}"]),
               "Same amount, check"
             )

      assert has_element?(view, "#statement-line-3 .backing", "Not backed")
      assert has_element?(view, "#statement-line-4 .backing", "Money in")
      assert has_element?(view, "#statement-coverage", "2 of 3 payments backed")
      assert has_element?(view, "#statement-tab-unbacked .count", "1")

      view |> element("#statement-tab-unbacked") |> render_click()
      assert_patch(view, ~p"/statements/#{statement}?filter=unbacked")
      assert has_element?(view, "#statement-line-3")
      refute has_element?(view, "#statement-line-1")
      refute has_element?(view, "#statement-line-4")

      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}?filter=credits")
      assert has_element?(view, "#statement-tab-credits.active")
      assert has_element?(view, "#statement-line-4")
      refute has_element?(view, "#statement-line-1")

      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}?filter=backed")
      assert has_element?(view, "#statement-line-1")
      assert has_element?(view, "#statement-line-2")
      refute has_element?(view, "#statement-line-3")
    end

    test "backs a line as soon as its invoice is booked elsewhere",
         %{conn: conn, scope: scope, account: account} do
      statement = read_october(scope, account, [{~D[2026-10-03], "SBB CFF FFS", -4_200}])

      {:ok, view, _html} = live(conn, ~p"/statements/#{statement}?filter=unbacked")
      assert has_element?(view, "#statement-line-1 .backing", "Not backed")
      assert has_element?(view, "#statement-coverage", "0 of 1 payment backed")

      entry = posted_entry(scope, "SBB", 4_200, "2026-10-01")

      assert has_element?(view, "#statement-tab-empty", "Every payment")
      refute has_element?(view, ".statement-line-cols")
      assert has_element?(view, "#statement-coverage", "1 of 1 payment backed")

      view |> element("#statement-tab-backed") |> render_click()

      assert has_element?(
               view,
               ~s(#statement-line-1 .backing a[href="/journal_entries/#{entry.id}"])
             )
    end

    test "the list shows how many payments of each read statement are backed",
         %{conn: conn, scope: scope, account: account} do
      read =
        read_october(scope, account, [
          {~D[2026-10-03], "ACME CORP", -4_200},
          {~D[2026-10-06], "Parking", -700},
          {~D[2026-10-10], "Payment, thank you", 10_000}
        ])

      processing = statement_fixture(scope, account)
      posted_entry(scope, "ACME Corp", 4_200, "2026-10-01")

      {:ok, view, _html} = live(conn, ~p"/statements")

      assert has_element?(view, "#statement-#{read.id}-coverage", "backed 1/2")
      refute has_element?(view, "#statement-#{processing.id}-coverage")

      posted_entry(scope, "Parking", 700, "2026-10-05")
      assert has_element?(view, "#statement-#{read.id}-coverage", "backed 2/2")
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
