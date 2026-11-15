defmodule ZaimuTomo.Statements.AttemptOutcomesTest do
  use ZaimuTomo.DataCase, async: false

  import ExUnit.CaptureLog
  import ZaimuTomo.AccountsFixtures, only: [user_scope_fixture: 0]
  import ZaimuTomo.FinancialAccountsFixtures, only: [financial_account_fixture: 2]
  import ZaimuTomo.StatementsFixtures, only: [put_extraction: 3, statement_fixture: 2]

  alias ZaimuTomo.Statements
  alias ZaimuTomo.Statements.{AttemptOutcomes, ExtractJob}
  alias ZaimuTomo.Storage.Memory

  @req_stub __MODULE__

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)

    for key <- [:langfuse, :mistral] do
      original = Application.get_env(:zaimu_tomo, key)
      on_exit(fn -> Application.put_env(:zaimu_tomo, key, original) end)
    end

    Application.put_env(:zaimu_tomo, :langfuse, enabled: false, environment: "test")

    Application.put_env(
      :zaimu_tomo,
      :mistral,
      Keyword.merge(Application.fetch_env!(:zaimu_tomo, :mistral),
        api_key: "test-key",
        req_options: [plug: {Req.Test, @req_stub}, retry: false]
      )
    )
  end

  setup {Req.Test, :set_req_test_to_shared}
  setup {Req.Test, :verify_on_exit!}

  defp upload(_context) do
    scope = user_scope_fixture()

    account =
      financial_account_fixture(scope, %{
        name: "Visa",
        account_type: :credit_card,
        currency: "CHF",
        account_number: "1234"
      })

    statement = statement_fixture(scope, account)
    Statements.subscribe(scope)

    %{scope: scope, account: account, statement: statement}
  end

  defp update_job(fields) do
    {1, _} = Repo.update_all(Oban.Job, set: fields)
    :ok
  end

  defp final_attempt(_context), do: update_job(max_attempts: 1)

  # A second Oban instance that runs for real, beside the manual test instance.
  defp start_oban!(opts) do
    start_supervised!(
      {Oban,
       Keyword.merge(
         [
           name: __MODULE__.Oban,
           repo: Repo,
           queues: [],
           plugins: [],
           stager: false,
           peer: Oban.Peers.Isolated,
           notifier: Oban.Notifiers.Isolated,
           testing: :disabled
         ],
         opts
       )}
    )
  end

  describe "attach/0 and error isolation" do
    test "attach/0 is idempotent" do
      assert :ok = AttemptOutcomes.attach()
      assert :ok = AttemptOutcomes.attach()
    end

    # :telemetry detaches a handler that raises, so handle_event/4 must not.
    test "an outcome the handler cannot process is logged instead of raised" do
      log =
        capture_log(fn ->
          AttemptOutcomes.handle_event(
            [:oban, :plugin, :stop],
            %{},
            %{plugin: Oban.Lifeline, discarded_jobs: [nil]},
            nil
          )
        end)

      assert log =~ "Attempt outcome not handled"
    end
  end

  describe "a final attempt that hit the job timeout" do
    setup [:upload, :final_attempt]

    test "records job_timeout and broadcasts statement_updated",
         %{scope: scope, statement: statement} do
      statement_id = statement.id
      test_pid = self()

      Req.Test.stub(@req_stub, fn _conn ->
        send(test_pid, {:running, self()})
        Process.sleep(:infinity)
      end)

      start_oban!(queues: [statements: 1])

      capture_log(fn ->
        Oban.Notifier.notify(__MODULE__.Oban, :insert, %{queue: "statements"})
        assert_receive {:running, job_pid}, 2_000

        # What Oban's timer does when ExtractJob.timeout/1 runs out.
        Process.exit(job_pid, Oban.TimeoutError.exception({ExtractJob, :timer.minutes(10)}))

        assert_receive {:statement_updated, ^statement_id}, 2_000
      end)

      read = Statements.get_reconciliation!(scope, statement_id).statement
      assert read.failure_code == "job_timeout"
      assert Statements.status(read) == :failed
      assert %Oban.Job{state: "discarded"} = Repo.one!(Oban.Job)
      refute_received {:statement_updated, ^statement_id}
    end
  end

  describe "a final attempt that crashed" do
    setup [:upload, :final_attempt]

    test "records unclassified without the exception text and broadcasts statement_updated",
         %{scope: scope, statement: statement} do
      statement_id = statement.id
      Req.Test.stub(@req_stub, fn _conn -> raise "secret body" end)

      capture_log(fn ->
        assert %{discard: 1} = Oban.drain_queue(queue: :statements)
      end)

      read = Statements.get_reconciliation!(scope, statement_id).statement
      assert read.failure_code == "unclassified"
      refute read.failure_code =~ "secret body"
      assert Statements.status(read) == :failed
      assert_received {:statement_updated, ^statement_id}
      refute_received {:statement_updated, ^statement_id}
    end

    test "is a no-op when the statement has already been deleted", %{statement: statement} do
      Req.Test.stub(@req_stub, fn _conn ->
        Repo.delete!(statement)
        raise "boom"
      end)

      log =
        capture_log(fn ->
          assert %{discard: 1} = Oban.drain_queue(queue: :statements)
        end)

      refute log =~ "Attempt outcome not handled"
      refute_received {:statement_updated, _}
    end
  end

  describe "a discarded retry of an already-extracted unbalanced statement" do
    setup :upload

    test "sets job_timeout, keeps earlier extracted_at and lines, and transitions to failed",
         %{scope: scope, statement: statement} do
      statement_id = statement.id
      update_job(state: "completed", completed_at: DateTime.utc_now())

      put_extraction(
        statement,
        %{currency: "CHF", opening_balance_cents: -10_000, closing_balance_cents: -6_700},
        [{~D[2026-10-03], "SBB CFF FFS", -4_200}]
      )

      extracted = Statements.get_reconciliation!(scope, statement_id).statement
      assert Statements.status(extracted) == :ready
      assert Statements.balance(extracted) == {:off_by, -7_500}

      assert {:ok, _retrying} = Statements.retry_extraction(scope, extracted)
      assert_received {:statement_updated, ^statement_id}

      retry_job = Repo.one!(from j in Oban.Job, where: j.state == "available")

      {1, _} =
        Repo.update_all(from(j in Oban.Job, where: j.id == ^retry_job.id),
          set: [state: "discarded", discarded_at: DateTime.utc_now()]
        )

      capture_log(fn ->
        AttemptOutcomes.handle_event(
          [:oban, :job, :exception],
          %{},
          %{
            job: Repo.reload!(retry_job),
            state: :discard,
            reason: Oban.TimeoutError.exception({ExtractJob, :timer.minutes(10)})
          },
          nil
        )
      end)

      assert_received {:statement_updated, ^statement_id}

      after_discard = Statements.get_reconciliation!(scope, statement_id).statement
      assert after_discard.failure_code == "job_timeout"
      assert after_discard.extracted_at == extracted.extracted_at
      assert length(after_discard.lines) == 1
      assert Statements.status(after_discard) == :failed
    end
  end

  describe "a job Oban.Lifeline discards after its node died" do
    setup :upload

    test "records job_interrupted, broadcasts, and ignores non-ExtractJob jobs",
         %{scope: scope, statement: statement} do
      statement_id = statement.id
      one_hour_ago = DateTime.add(DateTime.utc_now(), -1, :hour)

      other_job =
        %{}
        |> Oban.Job.new(worker: "ZaimuTomo.OtherWorker", queue: :default, max_attempts: 5)
        |> Repo.insert!()

      {2, _} =
        Repo.update_all(Oban.Job,
          set: [state: "executing", attempt: 5, max_attempts: 5, attempted_at: one_hour_ago]
        )

      log =
        capture_log(fn ->
          start_oban!(plugins: [{Oban.Lifeline, interval: 10, rescue_after: :timer.minutes(30)}])
          assert_receive {:statement_updated, ^statement_id}, 2_000
        end)

      read = Statements.get_reconciliation!(scope, statement_id).statement
      assert read.failure_code == "job_interrupted"
      assert Statements.status(read) == :failed
      assert %Oban.Job{state: "discarded"} = Repo.reload!(other_job)
      refute log =~ "Attempt outcome not handled"
      refute_received {:statement_updated, ^statement_id}
    end
  end

  describe "a discarded attempt whose outcome arrives after manual retry" do
    setup [:upload, :final_attempt]

    test "is a no-op when a live ExtractJob already exists for the statement",
         %{scope: scope, statement: statement} do
      statement_id = statement.id
      [discarded] = Repo.all(Oban.Job)
      update_job(state: "discarded", discarded_at: DateTime.utc_now())

      assert {:ok, _retrying} = Statements.retry_extraction(scope, statement)
      assert_received {:statement_updated, ^statement_id}

      AttemptOutcomes.handle_event(
        [:oban, :job, :exception],
        %{},
        %{
          job: Repo.reload!(discarded),
          state: :discard,
          reason: %RuntimeError{message: "boom"}
        },
        nil
      )

      read = Statements.get_reconciliation!(scope, statement_id).statement
      assert read.failure_code == nil
      assert Statements.status(read) == :processing
      refute_received {:statement_updated, ^statement_id}
    end
  end

  describe "a non-final failure exception" do
    setup :upload

    test "does nothing so retries keep waiting silently", %{scope: scope, statement: statement} do
      Req.Test.stub(@req_stub, fn _conn -> raise "boom" end)

      capture_log(fn ->
        assert %{failure: 1} = Oban.drain_queue(queue: :statements)
      end)

      read = Statements.get_reconciliation!(scope, statement.id).statement
      assert read.failure_code == nil
      assert Statements.status(read) == :processing
      assert %Oban.Job{state: "retryable"} = Repo.one!(Oban.Job)
      refute_received {:statement_updated, _}
    end
  end
end
