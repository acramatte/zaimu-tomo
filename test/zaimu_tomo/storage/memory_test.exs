defmodule ZaimuTomo.Storage.MemoryTest do
  use ExUnit.Case, async: false

  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  setup do
    Memory.reset()
    on_exit(&Memory.reset/0)
  end

  test "stores, streams, checks, and deletes an object through the configured facade" do
    key = "documents/invoice.pdf"

    destination =
      Path.join(System.tmp_dir!(), "zaimu-storage-#{System.unique_integer([:positive])}.pdf")

    on_exit(fn -> File.rm(destination) end)

    assert {:ok, ^key} = Storage.put_object(key, "invoice bytes")
    assert :ok = Storage.head_object(key)
    assert {:ok, ^destination} = Storage.get_object(key, destination)
    assert File.read!(destination) == "invoice bytes"
    assert :ok = Storage.delete_object(key)
    assert {:error, :not_found} = Storage.head_object(key)
  end

  test "returns not found when streaming a missing object" do
    destination =
      Path.join(System.tmp_dir!(), "zaimu-storage-#{System.unique_integer([:positive])}.pdf")

    on_exit(fn -> File.rm(destination) end)

    assert {:error, :not_found} = Storage.get_object("documents/missing.pdf", destination)
    refute File.exists?(destination)
  end
end
