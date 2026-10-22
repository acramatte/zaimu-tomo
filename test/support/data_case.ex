defmodule ZaimuTomo.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ZaimuTomo.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias ZaimuTomo.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import ZaimuTomo.DataCase
    end
  end

  setup tags do
    ZaimuTomo.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(ZaimuTomo.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  Makes every insert into `table` fail at the database with the constraint
  error that `changeset` declares for `field`.

  A test-owned `BEFORE INSERT` trigger raises the matching SQLSTATE with the
  declared constraint name, so Ecto maps it to a real
  `{:error, %Ecto.Changeset{}}` without altering the table's own constraints.
  The name comes from the changeset (not a hard-coded string), so a dependency
  renaming or dropping the constraint fails here instead of silently. The
  trigger and its `pg_temp` function roll back with the sandbox transaction.

      fail_inserts!("oban_jobs", Oban.Job.new(%{}, worker: "X"), :max_attempts)
  """
  def fail_inserts!(table, %Ecto.Changeset{} = changeset, field) do
    %{constraint: name, type: type} =
      Enum.find(changeset.constraints, &(&1.field == field)) ||
        raise ArgumentError,
              "#{inspect(changeset.data.__struct__)} declares no constraint on #{field}"

    sqlstate = %{check: "check_violation", foreign_key: "foreign_key_violation"}[type]

    ZaimuTomo.Repo.query!("""
    CREATE FUNCTION pg_temp.fail_#{table}_insert() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'test-injected failure' USING ERRCODE = '#{sqlstate}', CONSTRAINT = '#{name}';
    END
    $$ LANGUAGE plpgsql
    """)

    ZaimuTomo.Repo.query!(
      "CREATE TRIGGER fail_#{table}_insert BEFORE INSERT ON #{table} " <>
        "FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_#{table}_insert()"
    )

    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
