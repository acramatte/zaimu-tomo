defmodule ZaimuTomo.DocumentProcessing.WorkerLockTest do
  # Not sandboxed: the document row lock can only be told apart from the
  # expected-id recheck when the contenders run on independent connections
  # that really commit. A dedicated non-sandbox Repo instance (same
  # MIX_TEST_PARTITION database) provides them; rows are removed in on_exit.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ZaimuTomo.AccountsFixtures, only: [user_fixture: 0, user_scope_fixture: 1]

  alias ZaimuTomo.DocumentProcessing.ExtractedContent.ExtractedContent
  alias ZaimuTomo.DocumentProcessing.ExtractedData
  alias ZaimuTomo.DocumentProcessing.Worker
  alias ZaimuTomo.Documents.Document
  alias ZaimuTomo.Repo

  @repo_name :worker_lock_test_repo

  setup do
    {:ok, repo} =
      Repo.start_link(name: @repo_name, pool: DBConnection.ConnectionPool, pool_size: 6)

    # Unlinked so it outlives the test process until on_exit has cleaned up.
    Process.unlink(repo)
    Repo.put_dynamic_repo(@repo_name)

    user = user_fixture()
    scope = user_scope_fixture(user)

    {:ok, document} =
      %Document{}
      |> Document.changeset(
        %{filename: "lock-test.pdf", object_key: "documents/lock-test.pdf"},
        scope
      )
      |> Repo.insert()

    on_exit(fn ->
      Repo.put_dynamic_repo(@repo_name)
      Repo.delete_all(from(d in Document, where: d.user_id == ^user.id))
      Repo.delete!(user)
      Supervisor.stop(repo)
    end)

    %{document: document}
  end

  defp success(document), do: fn -> terminal_write(:success, document) end
  defp failure(document), do: fn -> terminal_write(:failure, document) end

  defp terminal_write(:success, document) do
    Worker.persist_and_emit_success(
      document,
      %ExtractedData{
        amount_to_pay_cents: 1000,
        invoice_date: "2024-01-15",
        invoice_number: "INV-001",
        currency: "USD",
        reason_for_payment: "Test payment",
        issuer: "Test Issuer"
      },
      %{},
      %{"status" => "not_run"},
      nil,
      "CHF",
      nil
    )
  end

  defp terminal_write(:failure, document) do
    Worker.persist_and_emit_failure(document, {:ocr_upload_failed, :enoent}, nil)
  end

  # Holds a row lock on the document from another connection. FOR NO KEY
  # UPDATE conflicts with the worker's FOR UPDATE but not with the foreign-key
  # share lock an insert takes, so only the explicit FOR UPDATE can make a
  # worker wait.
  defp hold_document_lock(document) do
    test = self()

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(@repo_name)

        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM documents WHERE id = $1 FOR NO KEY UPDATE", [document.id])
          send(test, :lock_held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :lock_held, 5_000
    task
  end

  defp release_lock(task) do
    send(task.pid, :release)
    assert {:ok, :ok} = Task.await(task)
  end

  defp run_blocked_contenders(document, contenders) do
    lock = hold_document_lock(document)

    tasks =
      for contender <- contenders do
        Task.async(fn ->
          Repo.put_dynamic_repo(@repo_name)
          contender.()
        end)
      end

    assert wait_for_blocked_backends(length(tasks)),
           "every contender must wait on the document row lock"

    release_lock(lock)
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp wait_for_blocked_backends(expected, attempts \\ 100) do
    %{rows: [[blocked]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND cardinality(pg_blocking_pids(pid)) > 0"
      )

    cond do
      blocked >= expected -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && wait_for_blocked_backends(expected, attempts - 1)
    end
  end

  defp terminal_rows(document) do
    Repo.all(from(e in ExtractedContent, where: e.document_id == ^document.id, select: e.status))
  end

  describe "row lock across independent connections" do
    test "two success contenders append exactly one row", %{document: document} do
      results = run_blocked_contenders(document, [success(document), success(document)])

      assert [{:error, :already_processed}, {:ok, _}] = Enum.sort_by(results, &elem(&1, 0))
      assert terminal_rows(document) == ["success"]
    end

    test "two failure contenders append exactly one row", %{document: document} do
      results = run_blocked_contenders(document, [failure(document), failure(document)])

      assert [{:error, :already_processed}, {:ok, _}] = Enum.sort_by(results, &elem(&1, 0))
      assert terminal_rows(document) == ["failed"]
    end

    test "a success and a failure contender append exactly one row", %{document: document} do
      results = run_blocked_contenders(document, [success(document), failure(document)])

      assert [{:error, :already_processed}, {:ok, winner}] = Enum.sort_by(results, &elem(&1, 0))
      assert terminal_rows(document) == [winner.status]
    end
  end
end
