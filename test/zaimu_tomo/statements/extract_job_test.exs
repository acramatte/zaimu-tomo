defmodule ZaimuTomo.Statements.ExtractJobTest do
  use ZaimuTomo.DataCase, async: false
  use Oban.Testing, repo: ZaimuTomo.Repo

  import ExUnit.CaptureLog
  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.FinancialAccountsFixtures
  import ZaimuTomo.StatementsFixtures

  alias ZaimuTomo.Statements
  alias ZaimuTomo.Statements.{ExtractJob, Statement}
  alias ZaimuTomo.Storage.Memory

  @stub __MODULE__

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)

    for key <- [:langfuse, :mistral, :ollama, :ai_workflow] do
      original = Application.get_env(:zaimu_tomo, key)
      on_exit(fn -> Application.put_env(:zaimu_tomo, key, original) end)
    end

    Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")

    Application.put_env(
      :zaimu_tomo,
      :mistral,
      Keyword.merge(Application.fetch_env!(:zaimu_tomo, :mistral),
        api_key: "test-key",
        req_options: [plug: {Req.Test, @stub}, retry: false]
      )
    )

    Application.put_env(:zaimu_tomo, :ollama,
      provider: :ollama,
      base_url: "http://llm.test/v1",
      req_options: [plug: {Req.Test, @stub}, retry: false]
    )

    Application.put_env(:zaimu_tomo, :ai_workflow,
      extractor: [backend: :ollama, model: "extractor"],
      verifier: [backend: :ollama, model: "verifier"]
    )

    scope = user_scope_fixture()

    account =
      financial_account_fixture(scope, %{
        name: "Visa",
        account_type: :credit_card,
        currency: "CHF",
        account_number: "1234"
      })

    %{scope: scope, account: account, statement: statement_fixture(scope, account)}
  end

  setup {Req.Test, :set_req_test_to_shared}
  setup {Req.Test, :verify_on_exit!}

  @page_1 %{
    "account_ref" => "XXXX XXXX XXXX 1234",
    "period_start" => "2026-10-01",
    "period_end" => "2026-10-31",
    "currency" => "CHF",
    "opening_balance_cents" => -10_000,
    "closing_balance_cents" => nil,
    "lines" => [
      %{
        "booking_date" => "2026-10-03",
        "description" => "SBB CFF FFS",
        "amount_cents" => 4_200,
        "direction" => "debit"
      },
      %{
        "booking_date" => "2026-10-10",
        "description" => "Payment, thank you",
        "amount_cents" => 10_000,
        "direction" => "credit"
      }
    ]
  }

  @page_2 %{
    "closing_balance_cents" => -6_700,
    "lines" => [
      %{
        "booking_date" => "2026-10-20",
        "description" => "Hotel Roma",
        "amount_cents" => 2_500,
        "direction" => "debit",
        "original_amount_cents" => 2_700,
        "original_currency" => "EUR"
      }
    ]
  }

  defp stub_pages(pages, opts \\ []) do
    test_pid = self()
    ocr_status = Keyword.get(opts, :ocr_status, 200)

    Req.Test.stub(@stub, fn conn ->
      path = conn.request_path

      cond do
        String.ends_with?(path, "/files") and ocr_status != 200 ->
          Plug.Conn.send_resp(conn, ocr_status, "unavailable")

        String.ends_with?(path, "/files") ->
          Req.Test.json(conn, %{"id" => "file-1"})

        String.ends_with?(path, "/url") ->
          Req.Test.json(conn, %{"url" => "https://files.test/file-1"})

        String.ends_with?(path, "/ocr") ->
          markdowns = Enum.map(1..length(pages), &%{"markdown" => "page #{&1} text"})
          Req.Test.json(conn, %{"pages" => markdowns})

        String.ends_with?(path, "/chat/completions") ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          prompt = body |> Jason.decode!() |> get_in(["messages", Access.at(0), "content"])
          [_, number] = Regex.run(~r/This is page (\d+) of/, prompt)
          send(test_pid, {:llm_prompt, prompt})
          completion(conn, Enum.at(pages, String.to_integer(number) - 1))
      end
    end)
  end

  defp completion(conn, page) do
    Req.Test.json(conn, %{
      id: "test",
      model: "extractor",
      choices: [
        %{
          index: 0,
          message: %{role: "assistant", content: Jason.encode!(page)},
          finish_reason: "stop"
        }
      ],
      usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
    })
  end

  defp run(statement, opts \\ []) do
    perform_job(ExtractJob, %{statement_id: statement.id}, opts)
  end

  defp read(statement), do: Statements.get_statement!(statement_scope(statement), statement.id)

  defp statement_scope(statement),
    do: %ZaimuTomo.Accounts.Scope{user: %ZaimuTomo.Accounts.User{id: statement.user_id}}

  test "reads every page into signed lines and a balanced header", %{statement: statement} do
    Statements.subscribe(statement_scope(statement))
    stub_pages([@page_1, @page_2])

    assert :ok = run(statement)

    read = read(statement)
    assert %DateTime{} = read.extracted_at
    assert read.failure_code == nil
    assert read.account_ref == "XXXX XXXX XXXX 1234"
    assert {read.period_start, read.period_end} == {~D[2026-10-01], ~D[2026-10-31]}
    assert {read.opening_balance_cents, read.closing_balance_cents} == {-10_000, -6_700}

    assert [
             {1, "SBB CFF FFS", -4_200, nil, nil},
             {2, "Payment, thank you", 10_000, nil, nil},
             {3, "Hotel Roma", -2_500, -2_700, "EUR"}
           ] =
             Enum.map(
               read.lines,
               &{&1.position, &1.description, &1.amount_cents, &1.original_amount_cents,
                &1.original_currency}
             )

    assert Enum.all?(read.lines, &(&1.currency == "CHF" and &1.user_id == statement.user_id))
    assert Statements.balance(read) == :balanced
    assert Statements.status(read, false) == :ready

    assert_receive {:llm_prompt, prompt}
    assert prompt =~ "This is page 1 of 2. The account is a credit card account in CHF."
    assert prompt =~ "Statement period printed on an earlier page: none yet."
    assert prompt =~ "page 1 text"

    assert_receive {:llm_prompt, prompt}
    assert prompt =~ "This is page 2 of 2."
    assert prompt =~ "Statement period printed on an earlier page: 2026-10-01 to 2026-10-31."
    assert_receive {:statement_updated, id} when id == statement.id
  end

  test "a transient error on a non-final attempt retries without recording anything",
       %{statement: statement} do
    stub_pages([@page_1], ocr_status: 503)

    capture_log(fn ->
      assert {:error, "ocr_upload_failed:http_503"} = run(statement, attempt: 1)
    end)

    read = read(statement)
    assert {read.extracted_at, read.failure_code, read.lines} == {nil, nil, []}
  end

  test "the final attempt records the failure, and a later failure keeps the earlier read",
       %{statement: statement} do
    stub_pages([@page_1, @page_2])
    assert :ok = run(statement)

    stub_pages([@page_1], ocr_status: 503)

    capture_log(fn -> assert :ok = run(statement, attempt: 5) end)

    read = read(statement)
    assert read.failure_code == "ocr_upload_failed:http_503"
    assert %DateTime{} = read.extracted_at
    assert length(read.lines) == 3
    assert Statements.status(read, false) == :failed
  end

  test "a statement that does not fit its account fails at once with the reason",
       %{statement: statement} do
    stub_pages([Map.put(@page_1, "currency", "EUR"), @page_2])

    assert :ok = run(statement, attempt: 1)
    assert read(statement).failure_code == "currency_mismatch"
  end

  test "a deleted statement cancels the job", %{scope: scope, statement: statement} do
    {:ok, _} = Statements.delete_statement(scope, statement)

    assert {:cancel, :statement_deleted} = run(statement)
  end

  test "a rerun replaces the lines and converges", %{statement: statement} do
    stub_pages([@page_1, @page_2])
    assert :ok = run(statement)
    first = read(statement)

    stub_pages([@page_1, @page_2])
    assert :ok = run(statement)
    second = read(statement)

    strip = fn s -> Enum.map(s.lines, &Map.drop(&1, [:id, :__meta__, :statement])) end
    assert strip.(first) == strip.(second)
    assert Repo.aggregate(Statements.StatementLine, :count) == 3
  end

  test "a second statement for the same account and period fails as a duplicate period",
       %{scope: scope, account: account, statement: statement} do
    stub_pages([@page_1, @page_2])
    assert :ok = run(statement)

    other = statement_fixture(scope, account)
    stub_pages([@page_1, @page_2])

    assert :ok = run(other)
    read = read(other)
    assert {read.failure_code, read.extracted_at, read.lines} == {"duplicate_period", nil, []}
    assert %Statement{failure_code: nil} = read(statement)
  end
end
