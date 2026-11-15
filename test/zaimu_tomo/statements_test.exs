defmodule ZaimuTomo.StatementsTest do
  use ZaimuTomo.DataCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo
  use ExUnitProperties

  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.FinancialAccountsFixtures
  import ZaimuTomo.ReviewFixtures, only: [journal_entry_fixture: 3]
  import ZaimuTomo.StatementsFixtures

  alias ZaimuTomo.FinancialAccounts
  alias ZaimuTomo.Statements
  alias ZaimuTomo.Statements.{ExtractJob, Reconciliation, Statement, StatementLine}
  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)

    scope = user_scope_fixture()
    %{scope: scope, account: financial_account_fixture(scope, %{name: "Main"})}
  end

  defp upload(scope, account_id, bytes, filename \\ "october.pdf") do
    path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    Statements.upload_statement(scope, account_id, path, filename)
  end

  defp stored_keys, do: Memory |> :ets.tab2list() |> Enum.map(&elem(&1, 0))

  defp drop_jobs, do: Repo.delete_all(Oban.Job)

  describe "upload_statement/4" do
    test "stores the file under statements/ and enqueues its extraction",
         %{scope: scope, account: account} do
      Statements.subscribe(scope)

      assert {:ok, %Statement{} = statement} = upload(scope, account.id, "october bytes")

      assert "statements/" <> _ = statement.object_key
      assert {:ok, "october bytes"} = Storage.read_object(statement.object_key)
      assert statement.filename == "october.pdf"
      assert statement.financial_account_id == account.id
      assert_enqueued(worker: ExtractJob, args: %{statement_id: statement.id})
      assert Statements.status(statement) == :processing
      assert_receive {:statement_updated, id} when id == statement.id
    end

    test "refuses an account of another user, or no account, and stores nothing",
         %{scope: scope} do
      foreign = financial_account_fixture(user_scope_fixture())

      for account_id <- [foreign.id, Integer.to_string(foreign.id), "not-an-id", nil] do
        assert {:error, %Ecto.Changeset{} = changeset} = upload(scope, account_id, "bytes")
        assert %{financial_account_id: ["does not exist"]} = errors_on(changeset)
      end

      assert stored_keys() == []
      refute_enqueued(worker: ExtractJob)
    end

    test "refuses a filename longer than 255 characters and deletes the stored object",
         %{scope: scope, account: account} do
      long_filename = String.duplicate("a", 252) <> ".pdf"

      assert {:error, %Ecto.Changeset{} = changeset} =
               upload(scope, account.id, "bytes", long_filename)

      assert %{filename: ["should be at most 255 character(s)"]} = errors_on(changeset)
      assert stored_keys() == []
      refute_enqueued(worker: ExtractJob)
    end

    test "returns the earlier statement for the same bytes and deletes the new object",
         %{scope: scope, account: account} do
      {:ok, first} = upload(scope, account.id, "same bytes")

      assert {:error, {:already_uploaded, %Statement{id: id}}} =
               upload(scope, account.id, "same bytes")

      assert id == first.id
      assert stored_keys() == [first.object_key]
      assert [_] = all_enqueued(worker: ExtractJob)
    end

    test "another user may upload the same bytes", %{scope: scope, account: account} do
      {:ok, _} = upload(scope, account.id, "same bytes")
      other = user_scope_fixture()
      other_account = financial_account_fixture(other)

      assert {:ok, _} = upload(other, other_account.id, "same bytes")
    end

    test "the database refuses a second live job for one statement",
         %{scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      [job] = all_enqueued(worker: ExtractJob)

      unchecked =
        statement |> ExtractJob.new_for() |> Ecto.Changeset.put_change(:unique, nil)

      for state <- ExtractJob.live_states() do
        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
          set: [state: Atom.to_string(state)]
        )

        assert {:error, %Ecto.Changeset{errors: [args: {"has already been taken", opts}]}} =
                 Oban.insert(unchecked)

        assert opts[:constraint] == :unique
        assert opts[:constraint_name] == "oban_jobs_one_live_extract_job_per_statement"
      end

      for state <- [:completed, :discarded, :cancelled] do
        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
          set: [state: Atom.to_string(state)]
        )

        assert {:ok, inserted} = Oban.insert(unchecked)
        Repo.delete!(inserted)
      end
    end
  end

  describe "reads" do
    test "list_statements/1 lists only the scope's statements with their status",
         %{scope: scope, account: account} do
      processing = statement_fixture(scope, account)
      ready = scope |> statement_fixture(account) |> put_extraction()
      foreign_scope = user_scope_fixture()
      statement_fixture(foreign_scope, financial_account_fixture(foreign_scope))

      Repo.delete_all(
        from j in Oban.Job, where: fragment("?->>'statement_id'", j.args) == ^"#{ready.id}"
      )

      assert [
               %{statement: %{id: first_id}, status: :processing},
               %{statement: %{id: second_id, financial_account: %{name: "Main"}}, status: :ready}
             ] = Statements.list_statements(scope)

      assert {first_id, second_id} == {processing.id, ready.id}
    end

    test "status/2 is the one status rule" do
      read = %Statement{extracted_at: DateTime.utc_now()}

      assert Statements.status(
               %Statement{failure_code: "x", extracted_at: DateTime.utc_now()},
               true
             ) ==
               :processing

      assert Statements.status(%Statement{read | failure_code: "ocr"}, false) == :failed
      assert Statements.status(read, false) == :ready
      assert Statements.status(%Statement{}, false) == :stalled
    end

    test "list_statement_object_keys/0 returns persisted keys in id order across users",
         %{scope: scope, account: account} do
      first = statement_fixture(scope, account)
      other_scope = user_scope_fixture()
      other_account = financial_account_fixture(other_scope)
      second = statement_fixture(other_scope, other_account)

      assert Statements.list_statement_object_keys() == [first.object_key, second.object_key]
    end

    test "has_live_job?/1 reports whether an extraction job is live",
         %{scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      assert Statements.has_live_job?(statement.id)

      drop_jobs()
      refute Statements.has_live_job?(statement.id)
    end
  end

  describe "balance/1" do
    property "the balance is the gap between opening plus lines and closing" do
      check all(
              opening <- integer(),
              closing <- integer(),
              amounts <- list_of(integer())
            ) do
        statement = %Statement{
          extracted_at: DateTime.utc_now(),
          opening_balance_cents: opening,
          closing_balance_cents: closing,
          lines: Enum.map(amounts, &%{amount_cents: &1})
        }

        case opening + Enum.sum(amounts) - closing do
          0 -> assert Statements.balance(statement) == :balanced
          gap -> assert Statements.balance(statement) == {:off_by, gap}
        end
      end
    end

    test "a statement not read yet has no balance" do
      assert Statements.balance(%Statement{extracted_at: nil}) == nil
    end

    test "raises when :lines are not preloaded on a read statement",
         %{scope: scope, account: account} do
      statement = scope |> statement_fixture(account) |> put_extraction()
      unloaded = Repo.get!(Statement, statement.id)

      assert_raise ArgumentError, "Statements.balance/1 requires :lines to be preloaded", fn ->
        Statements.balance(unloaded)
      end
    end
  end

  describe "retry_extraction/2" do
    test "enqueues a stalled, failed, or unbalanced statement and broadcasts",
         %{scope: scope, account: account} do
      Statements.subscribe(scope)
      stalled = statement_fixture(scope, account)

      failed = scope |> statement_fixture(account) |> put_failure("ocr")

      unbalanced =
        scope
        |> statement_fixture(account)
        |> put_extraction(%{
          period_start: ~D[2026-09-01],
          period_end: ~D[2026-09-30],
          closing_balance_cents: 1
        })

      drop_jobs()

      for statement <- [stalled, failed, unbalanced] do
        assert {:ok, %Statement{}} = Statements.retry_extraction(scope, statement)
        assert_enqueued(worker: ExtractJob, args: %{statement_id: statement.id})
        assert_receive {:statement_updated, id} when id == statement.id
      end
    end

    test "refuses a statement that is processing or read and balanced",
         %{scope: scope, account: account} do
      processing = statement_fixture(scope, account)
      assert {:error, :not_retryable} = Statements.retry_extraction(scope, processing)

      balanced = scope |> statement_fixture(account) |> put_extraction()
      drop_jobs()
      assert {:error, :not_retryable} = Statements.retry_extraction(scope, balanced)
      refute_enqueued(worker: ExtractJob)
    end

    test "treats another user's statement as missing", %{scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      drop_jobs()

      assert {:error, :not_found} = Statements.retry_extraction(user_scope_fixture(), statement)
      refute_enqueued(worker: ExtractJob)
    end
  end

  test "describe_failure/1 words a read that does not fit its account, and defers the rest" do
    assert Statements.describe_failure("account_mismatch") ==
             "it names another account than this one"

    assert Statements.describe_failure("line_outside_period") ==
             "a line is dated months away from the statement's period"

    assert Statements.describe_failure("duplicate_period") ==
             "this account already has a statement for this period"

    assert Statements.describe_failure("llm_request_failed:http_429") ==
             "the extraction service was rate-limited"

    assert Statements.describe_failure("validation_failed") ==
             "the extraction service returned an answer that could not be understood"
  end

  describe "delete_statement/2" do
    test "deletes the row, its lines, then the file, and broadcasts",
         %{scope: scope, account: account} do
      Statements.subscribe(scope)

      statement =
        scope |> statement_fixture(account) |> put_extraction(%{}, [{~D[2026-10-01], "a", -100}])

      assert {:ok, _} = Statements.delete_statement(scope, statement)

      refute Repo.get(Statement, statement.id)
      assert Repo.aggregate(StatementLine, :count) == 0
      assert {:error, :not_found} = Storage.read_object(statement.object_key)
      assert_receive {:statement_deleted, id} when id == statement.id
    end

    test "treats another user's statement as missing", %{scope: scope, account: account} do
      statement = statement_fixture(scope, account)

      assert {:error, :not_found} = Statements.delete_statement(user_scope_fixture(), statement)
      assert Repo.get(Statement, statement.id)
      assert {:ok, _} = Storage.read_object(statement.object_key)
    end

    test "returns :not_found when the statement was already deleted",
         %{scope: scope, account: account} do
      Statements.subscribe(scope)
      statement = statement_fixture(scope, account)

      assert {:ok, _} = Statements.delete_statement(scope, statement)
      assert_receive {:statement_deleted, id} when id == statement.id

      assert {:error, :not_found} = Statements.delete_statement(scope, statement)
      refute_receive {:statement_deleted, _}
    end

    test "an account keeps its statements: deleting it fails until they are deleted",
         %{scope: scope, account: account} do
      statement = statement_fixture(scope, account)

      assert {:error, changeset} = FinancialAccounts.delete_financial_account(scope, account)

      assert errors_on(changeset) == %{
               statements: ["has statements; delete its statements first"]
             }

      assert Repo.get(Statement, statement.id)

      assert {:ok, _} = Statements.delete_statement(scope, statement)
      assert {:ok, _} = FinancialAccounts.delete_financial_account(scope, account)
    end
  end

  describe "reconcile/2" do
    defp read_statement(scope, account, period_start, lines) do
      scope
      |> statement_fixture(account)
      |> put_extraction(
        %{
          period_start: period_start,
          period_end: Date.end_of_month(period_start),
          currency: account.currency
        },
        lines
      )
    end

    defp backings(%Reconciliation{rows: rows}) do
      Enum.map(rows, fn
        %{line: line, backing: {:matched, entry, confidence}} ->
          {line.description, entry.id, confidence}

        %{line: line, backing: :unbacked} ->
          {line.description, :unbacked}
      end)
    end

    defp entry(scope, issuer, cents, currency, date, opts \\ []) do
      journal_entry_fixture(
        scope,
        %{issuer: issuer, amount_to_pay_cents: cents, currency: currency, invoice_date: date},
        opts
      )
    end

    test "backs each debit with a posted entry of its amount in the window, credits never",
         %{scope: scope, account: account} do
      statement =
        read_statement(scope, account, ~D[2026-10-01], [
          {~D[2026-10-03], "ACME CORP ZURICH", -4_200},
          {~D[2026-10-05], "CARD 1234 SHOP", -1_500},
          {~D[2026-10-06], "Unbooked uncategorized", -2_000},
          {~D[2026-10-07], "Too late an invoice", -3_000},
          {~D[2026-10-10], "Refund", 1_500}
        ])

      named = entry(scope, "ACME Corp", 4_200, "EUR", "2026-10-01")
      amount_only = entry(scope, "Bakery Muller", 1_500, "EUR", "2026-09-20")
      entry(scope, "Uncategorized", 2_000, "EUR", "2026-10-01", post: false)
      entry(scope, "Old", 3_000, "EUR", "2026-07-01")
      drop_jobs()

      id = statement.id
      assert %{^id => reconciliation} = Statements.reconcile(scope, [id])

      assert backings(reconciliation) == [
               {"ACME CORP ZURICH", named.id, :named},
               {"CARD 1234 SHOP", amount_only.id, :amount_only},
               {"Unbooked uncategorized", :unbacked},
               {"Too late an invoice", :unbacked},
               {"Refund", :unbacked}
             ]

      assert reconciliation.summary == %{debits: 4, debits_backed: 2, credits: 1}
      assert reconciliation.status == :ready
      assert reconciliation.balance == :balanced

      assert Enum.map(Reconciliation.rows(reconciliation, :backed), & &1.line.description) ==
               ["ACME CORP ZURICH", "CARD 1234 SHOP"]

      assert Enum.map(Reconciliation.rows(reconciliation, :unbacked), & &1.line.description) ==
               ["Unbooked uncategorized", "Too late an invoice"]

      assert Enum.map(Reconciliation.rows(reconciliation, :credits), & &1.line.description) ==
               ["Refund"]

      assert length(Reconciliation.rows(reconciliation, :all)) == 5
    end

    test "an entry posted after the upload backs its line on the next read",
         %{scope: scope, account: account} do
      statement = read_statement(scope, account, ~D[2026-10-01], [{~D[2026-10-03], "Shop", -900}])

      assert backings(Statements.reconcile(scope, [statement.id])[statement.id]) ==
               [{"Shop", :unbacked}]

      posted = entry(scope, "Shop", 900, "EUR", "2026-10-02")

      assert backings(Statements.reconcile(scope, [statement.id])[statement.id]) ==
               [{"Shop", posted.id, :named}]
    end

    test "one entry backs one line across two statements, whichever is read",
         %{scope: scope, account: account} do
      october = read_statement(scope, account, ~D[2026-10-01], [{~D[2026-10-03], "Gym", -4_200}])
      november = read_statement(scope, account, ~D[2026-11-01], [{~D[2026-11-02], "Gym", -4_200}])
      gym = entry(scope, "Gym", 4_200, "EUR", "2026-10-01")

      both = Statements.reconcile(scope, [october.id, november.id])

      for reconciliations <- [
            both,
            Statements.reconcile(scope, [october.id]),
            Statements.reconcile(scope, [november.id])
          ],
          {id, reconciliation} <- reconciliations do
        assert backings(reconciliation) == backings(both[id])
      end

      assert backings(both[october.id]) == [{"Gym", gym.id, :named}]
      assert backings(both[november.id]) == [{"Gym", :unbacked}]
    end

    test "a foreign-amount line bridges two amount groups",
         %{scope: scope, account: account} do
      # The September card line has a EUR key and a USD key. Read alone, the
      # October line reaches only the EUR key, yet must not take the EUR entry
      # from the September line, because that line takes the named USD entry.
      september =
        read_statement(scope, account, ~D[2026-09-01], [
          {~D[2026-09-28], "ACME SAN FRANCISCO", -4_200, {-5_000, "USD"}}
        ])

      october = read_statement(scope, account, ~D[2026-10-01], [{~D[2026-10-05], "Cafe", -4_200}])

      eur = entry(scope, "Other", 4_200, "EUR", "2026-09-27")
      usd = entry(scope, "ACME Corp", 5_000, "USD", "2026-09-27")

      assert backings(Statements.reconcile(scope, [october.id])[october.id]) == [
               {"Cafe", eur.id, :amount_only}
             ]

      assert backings(Statements.reconcile(scope, [september.id])[september.id]) ==
               [{"ACME SAN FRANCISCO", usd.id, :named}]
    end

    test "another user's entries never back a line", %{scope: scope, account: account} do
      statement = read_statement(scope, account, ~D[2026-10-01], [{~D[2026-10-03], "Shop", -900}])
      entry(user_scope_fixture(), "Shop", 900, "EUR", "2026-10-02")

      assert backings(Statements.reconcile(scope, [statement.id])[statement.id]) ==
               [{"Shop", :unbacked}]
    end

    test "a missing or foreign statement id is left out", %{scope: scope, account: account} do
      foreign_scope = user_scope_fixture()
      foreign = statement_fixture(foreign_scope, financial_account_fixture(foreign_scope))

      statement =
        read_statement(scope, account, ~D[2026-10-01], [
          {~D[2026-10-02], "b", -200},
          {~D[2026-10-01], "a", 500}
        ])

      assert %{} == Statements.reconcile(scope, [foreign.id, -1])

      assert [%{line: %{description: "b"}}, %{line: %{description: "a"}}] =
               Statements.reconcile(scope, [statement.id, foreign.id])[statement.id].rows
    end

    test "get_reconciliation/2 and its bang read one of the scope's statements",
         %{scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      foreign_scope = user_scope_fixture()
      foreign = statement_fixture(foreign_scope, financial_account_fixture(foreign_scope))

      for id <- [statement.id, to_string(statement.id)] do
        assert %Reconciliation{statement: read} = Statements.get_reconciliation(scope, id)
        assert read.id == statement.id
        assert Statements.get_reconciliation!(scope, id).statement.id == statement.id
      end

      for id <- [foreign.id, -1, "not-an-id"] do
        assert Statements.get_reconciliation(scope, id) == nil
        assert_raise Ecto.NoResultsError, fn -> Statements.get_reconciliation!(scope, id) end
      end
    end
  end
end
