defmodule ZaimuTomo.Storage.MigrationTest do
  use ZaimuTomo.DataCase, async: false

  import ZaimuTomo.AccountsFixtures
  import ZaimuTomo.DocumentsFixtures

  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory
  alias ZaimuTomo.Storage.Migration

  setup do
    Memory.reset()

    source_dir =
      Path.join(System.tmp_dir!(), "zaimu-tomo-migration-#{System.unique_integer([:positive])}")

    File.mkdir_p!(source_dir)

    on_exit(fn ->
      Memory.reset()
      File.rm_rf(source_dir)
    end)

    %{scope: user_scope_fixture(), source_dir: source_dir}
  end

  test "uploads missing objects and skips them on a safe rerun", %{
    scope: scope,
    source_dir: source_dir
  } do
    object_key = "documents/legacy-invoice.pdf"
    document_fixture(scope, %{filename: "legacy-invoice.pdf", object_key: object_key})
    source_path = Path.join(source_dir, "legacy-invoice.pdf")
    File.write!(source_path, "legacy bytes")

    assert {:ok, %{uploaded: 1, skipped_existing: 0, missing_sources: [], failures: []}} =
             Migration.migrate(source_dir)

    assert :ok = Storage.head_object(object_key)
    File.rm!(source_path)

    assert {:ok, %{uploaded: 0, skipped_existing: 1, missing_sources: [], failures: []}} =
             Migration.migrate(source_dir)
  end

  test "reports every missing legacy source", %{scope: scope, source_dir: source_dir} do
    object_key = "documents/missing.pdf"
    document_fixture(scope, %{filename: "missing.pdf", object_key: object_key})

    assert {:error, summary} = Migration.migrate(source_dir)
    assert summary.uploaded == 0
    assert summary.skipped_existing == 0
    assert summary.failures == []

    assert summary.missing_sources == [
             %{object_key: object_key, path: Path.join(source_dir, "missing.pdf")}
           ]

    assert Migration.format_summary(summary) =~ "Missing source:"
  end

  test "reports upload failures without deleting the source", %{
    scope: scope,
    source_dir: source_dir
  } do
    object_key = "documents/unavailable.pdf"
    document_fixture(scope, %{filename: "unavailable.pdf", object_key: object_key})
    source_path = Path.join(source_dir, "unavailable.pdf")
    File.write!(source_path, "legacy bytes")

    original_config = Application.fetch_env!(:zaimu_tomo, :storage)

    Application.put_env(
      :zaimu_tomo,
      :storage,
      Keyword.put(original_config, :adapter, ZaimuTomo.Storage.MigrationTest.FailingPutStorage)
    )

    on_exit(fn -> Application.put_env(:zaimu_tomo, :storage, original_config) end)

    assert {:error,
            %{failures: [%{object_key: ^object_key, operation: :put, reason: :unavailable}]}} =
             Migration.migrate(source_dir)

    assert File.read!(source_path) == "legacy bytes"
  end

  defmodule FailingPutStorage do
    def put_object(_key, _body, _config), do: {:error, :unavailable}
    def get_object(_key, _destination, _config), do: {:error, :not_found}
    def delete_object(_key, _config), do: :ok
    def head_object(_key, _config), do: {:error, :not_found}
  end
end
