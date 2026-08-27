defmodule ZaimuTomo.StorageTest do
  use ExUnit.Case

  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  setup do
    Memory.reset()
    :ok
  end

  test "read_object returns binary for stored key via adapter" do
    assert {:ok, "documents/x.txt"} = Storage.put_object("documents/x.txt", "hello")
    assert {:ok, "hello"} = Storage.read_object("documents/x.txt")
  end

  test "read_object returns not_found when missing" do
    assert {:error, :not_found} = Storage.read_object("does-not-exist")
  end
end
