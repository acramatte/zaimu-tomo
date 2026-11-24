defmodule ZaimuTomo.Statements.DatabaseGuardsTest do
  use ZaimuTomo.DataCase, async: false

  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.FinancialAccountsFixtures
  import ZaimuTomo.StatementsFixtures

  alias ZaimuTomo.Fingerprint
  alias ZaimuTomo.Statements.{Statement, StatementLine}
  alias ZaimuTomo.Storage.Memory

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)

    scope = user_scope_fixture()
    %{scope: scope, account: financial_account_fixture(scope, %{name: "Main"})}
  end

  defp statement_row(statement), do: from(s in Statement, where: s.id == ^statement.id)

  defp valid_statement_row(scope, account, overrides \\ %{}) do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now(:second)

    Map.merge(
      %{
        user_id: scope.user.id,
        financial_account_id: account.id,
        filename: "raw-#{n}.pdf",
        object_key: "statements/raw-#{n}.pdf",
        content_sha256: Fingerprint.sha256("raw-statement-#{n}"),
        inserted_at: now,
        updated_at: now
      },
      overrides
    )
  end

  defp valid_extracted_header do
    [
      extracted_at: DateTime.utc_now(:second),
      period_start: ~D[2026-10-01],
      period_end: ~D[2026-10-31],
      currency: "EUR",
      opening_balance_cents: 100_000,
      closing_balance_cents: 100_000
    ]
  end

  defp valid_line_row(statement, overrides \\ %{}) do
    Map.merge(
      %{
        statement_id: statement.id,
        user_id: statement.user_id,
        position: System.unique_integer([:positive]),
        booking_date: ~D[2026-10-15],
        description: "Coffee",
        amount_cents: -500,
        currency: statement.currency
      },
      overrides
    )
  end

  describe "statements_initial_state_check" do
    test "refuses inserting a statement with extracted_at or failure_code already set",
         %{scope: scope, account: account} do
      extracted_fields = Map.new(valid_extracted_header())

      for overrides <- [
            extracted_fields,
            %{failure_code: "ocr_failed"},
            Map.put(extracted_fields, :failure_code, "ocr_failed")
          ] do
        assert_raise Postgrex.Error, ~r/statements_initial_state_check/, fn ->
          Repo.insert_all(Statement, [valid_statement_row(scope, account, overrides)])
        end
      end

      assert {1, nil} = Repo.insert_all(Statement, [valid_statement_row(scope, account)])
    end
  end

  describe "statements_extracted_header" do
    test "refuses setting any header column while extracted_at is nil",
         %{scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      row = statement_row(statement)

      for set <- [
            [account_ref: "XXXX 1234"],
            [period_start: ~D[2026-10-01]],
            [period_end: ~D[2026-10-31]],
            [currency: "EUR"],
            [opening_balance_cents: 100_000],
            [closing_balance_cents: 100_000],
            Keyword.delete(valid_extracted_header(), :extracted_at)
          ] do
        assert_raise Postgrex.Error, ~r/statements_extracted_header/, fn ->
          Repo.update_all(row, set: set)
        end
      end

      assert %Statement{extracted_at: nil, currency: nil} = Repo.get!(Statement, statement.id)
    end

    test "refuses setting extracted_at without every required header column or with inverted period",
         %{scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      row = statement_row(statement)
      header = valid_extracted_header()

      for missing <- [
            :period_start,
            :period_end,
            :currency,
            :opening_balance_cents,
            :closing_balance_cents
          ] do
        assert_raise Postgrex.Error, ~r/statements_extracted_header/, fn ->
          Repo.update_all(row, set: Keyword.delete(header, missing))
        end
      end

      inverted =
        header
        |> Keyword.put(:period_start, ~D[2026-10-31])
        |> Keyword.put(:period_end, ~D[2026-10-01])

      assert_raise Postgrex.Error, ~r/statements_extracted_header/, fn ->
        Repo.update_all(row, set: inverted)
      end

      single_day =
        header
        |> Keyword.put(:period_start, ~D[2026-10-15])
        |> Keyword.put(:period_end, ~D[2026-10-15])

      assert {1, _} = Repo.update_all(row, set: single_day)
    end
  end

  describe "statements_extracted_at_monotonic_check" do
    test "refuses clearing extracted_at once set while allowing failure_code on an extracted statement",
         %{scope: scope, account: account} do
      statement = scope |> statement_fixture(account) |> put_extraction()
      row = statement_row(statement)

      assert_raise Postgrex.Error, ~r/statements_extracted_at_monotonic_check/, fn ->
        Repo.update_all(row,
          set: [
            extracted_at: nil,
            account_ref: nil,
            period_start: nil,
            period_end: nil,
            currency: nil,
            opening_balance_cents: nil,
            closing_balance_cents: nil
          ]
        )
      end

      assert {1, _} = Repo.update_all(row, set: [failure_code: "ocr_failed"])

      reloaded = Repo.get!(Statement, statement.id)
      assert reloaded.extracted_at == statement.extracted_at
      assert reloaded.failure_code == "ocr_failed"
      assert reloaded.closing_balance_cents == statement.closing_balance_cents

      later = DateTime.add(statement.extracted_at, 60, :second)
      assert {1, _} = Repo.update_all(row, set: [extracted_at: later, failure_code: nil])
      assert Repo.get!(Statement, statement.id).extracted_at == later
    end
  end

  describe "statements_upload_immutable_check" do
    test "refuses changing user_id, financial_account_id, object_key, or content_sha256 after insert",
         %{scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      row = statement_row(statement)
      other_scope = user_scope_fixture()
      second_account = financial_account_fixture(scope, %{name: "Savings"})

      for set <- [
            [user_id: other_scope.user.id],
            [financial_account_id: second_account.id],
            [object_key: "statements/different.pdf"],
            [content_sha256: Fingerprint.sha256("different bytes")]
          ] do
        assert_raise Postgrex.Error, ~r/statements_upload_immutable_check/, fn ->
          Repo.update_all(row, set: set)
        end
      end

      reloaded = Repo.get!(Statement, statement.id)
      assert reloaded.user_id == statement.user_id
      assert reloaded.financial_account_id == statement.financial_account_id
      assert reloaded.object_key == statement.object_key
      assert reloaded.content_sha256 == statement.content_sha256

      assert {1, _} = Repo.update_all(row, set: [failure_code: "ocr_failed"])
    end
  end

  describe "statements column checks" do
    test "statements_failure_code_not_empty refuses an empty string",
         %{scope: scope, account: account} do
      statement = statement_fixture(scope, account)
      row = statement_row(statement)

      assert_raise Postgrex.Error, ~r/statements_failure_code_not_empty/, fn ->
        Repo.update_all(row, set: [failure_code: ""])
      end

      assert {1, _} = Repo.update_all(row, set: [failure_code: "ocr_failed"])
      assert {1, _} = Repo.update_all(row, set: [failure_code: nil])
    end

    test "statements_object_key_prefix refuses keys outside statements/",
         %{scope: scope, account: account} do
      for bad_key <- ["documents/abc.pdf", "abc.pdf", ""] do
        assert_raise Postgrex.Error, ~r/statements_object_key_prefix/, fn ->
          Repo.insert_all(Statement, [valid_statement_row(scope, account, %{object_key: bad_key})])
        end
      end
    end

    test "statements_content_sha256_format refuses non-64-lowercase-hex digests",
         %{scope: scope, account: account} do
      for bad_sha <- [
            "not-a-sha",
            String.duplicate("a", 63),
            String.duplicate("A", 64),
            String.duplicate("g", 64)
          ] do
        assert_raise Postgrex.Error, ~r/statements_content_sha256_format/, fn ->
          Repo.insert_all(Statement, [
            valid_statement_row(scope, account, %{content_sha256: bad_sha})
          ])
        end
      end
    end

    test "statements_currency_format refuses non-ISO currency codes",
         %{scope: scope, account: account} do
      statement = scope |> statement_fixture(account) |> put_extraction()
      row = statement_row(statement)

      for bad_currency <- ["chf", "EU", "123", ""] do
        assert_raise Postgrex.Error, ~r/statements_currency_format/, fn ->
          Repo.update_all(row, set: [currency: bad_currency])
        end
      end
    end
  end

  describe "composite foreign keys" do
    test "statements_financial_account_id_fkey refuses another user's financial account",
         %{scope: scope} do
      other_scope = user_scope_fixture()
      other_account = financial_account_fixture(other_scope, %{name: "Foreign"})

      assert_raise Postgrex.Error, ~r/statements_financial_account_id_fkey/, fn ->
        Repo.insert_all(Statement, [valid_statement_row(scope, other_account)])
      end
    end

    test "statement_lines_statement_id_fkey refuses unextracted statements and tenant or currency mismatches",
         %{scope: scope, account: account} do
      unextracted = statement_fixture(scope, account)
      extracted = scope |> statement_fixture(account) |> put_extraction()
      other_scope = user_scope_fixture()

      for line <- [
            valid_line_row(unextracted, %{currency: "EUR"}),
            valid_line_row(extracted, %{user_id: other_scope.user.id}),
            valid_line_row(extracted, %{currency: "USD"})
          ] do
        assert_raise Postgrex.Error, ~r/statement_lines_statement_id_fkey/, fn ->
          Repo.insert_all(StatementLine, [line])
        end
      end

      assert {1, nil} = Repo.insert_all(StatementLine, [valid_line_row(extracted)])
    end
  end

  describe "statement_lines column checks" do
    test "statement_lines_position_positive refuses zero and negative positions",
         %{scope: scope, account: account} do
      extracted = scope |> statement_fixture(account) |> put_extraction()

      for bad_position <- [0, -1] do
        assert_raise Postgrex.Error, ~r/statement_lines_position_positive/, fn ->
          Repo.insert_all(StatementLine, [valid_line_row(extracted, %{position: bad_position})])
        end
      end
    end

    test "statement_lines_original_amount_not_zero refuses zero original_amount_cents",
         %{scope: scope, account: account} do
      extracted = scope |> statement_fixture(account) |> put_extraction()

      assert_raise Postgrex.Error, ~r/statement_lines_original_amount_not_zero/, fn ->
        Repo.insert_all(StatementLine, [
          valid_line_row(extracted, %{
            amount_cents: -100,
            original_amount_cents: 0,
            original_currency: "USD"
          })
        ])
      end
    end

    test "statement_lines_original_amount_same_sign refuses opposite signs and allows matching signs",
         %{scope: scope, account: account} do
      extracted = scope |> statement_fixture(account) |> put_extraction()

      for {amount, original} <- [{-100, 100}, {100, -100}] do
        assert_raise Postgrex.Error, ~r/statement_lines_original_amount_same_sign/, fn ->
          Repo.insert_all(StatementLine, [
            valid_line_row(extracted, %{
              amount_cents: amount,
              original_amount_cents: original,
              original_currency: "USD"
            })
          ])
        end
      end

      for {amount, original} <- [{-100, -120}, {100, 120}] do
        assert {1, nil} =
                 Repo.insert_all(StatementLine, [
                   valid_line_row(extracted, %{
                     amount_cents: amount,
                     original_amount_cents: original,
                     original_currency: "USD"
                   })
                 ])
      end
    end

    test "statement_lines_currency_format refuses non-ISO currency codes",
         %{scope: scope, account: account} do
      extracted = scope |> statement_fixture(account) |> put_extraction()

      # Postgres evaluates CHECK constraints before AFTER-trigger FK checks, so a
      # malformed currency hits the column format check directly.
      for bad_currency <- ["eur", "EU", "123", ""] do
        assert_raise Postgrex.Error, ~r/statement_lines_currency_format/, fn ->
          Repo.insert_all(StatementLine, [valid_line_row(extracted, %{currency: bad_currency})])
        end
      end
    end

    test "statement_lines_original_currency_format refuses non-ISO original_currency codes",
         %{scope: scope, account: account} do
      extracted = scope |> statement_fixture(account) |> put_extraction()

      for bad_currency <- ["usd", "US", "123", ""] do
        assert_raise Postgrex.Error, ~r/statement_lines_original_currency_format/, fn ->
          Repo.insert_all(StatementLine, [
            valid_line_row(extracted, %{
              amount_cents: -100,
              original_amount_cents: -120,
              original_currency: bad_currency
            })
          ])
        end
      end
    end
  end
end
