defmodule ZaimuTomo.StorageTest do
  use ExUnit.Case

  alias ZaimuTomo.Storage
  alias ZaimuTomo.Storage.Memory

  # Published SHA-256 test vector (FIPS 180-2).
  @abc_sha256 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

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

  describe "store_upload/3" do
    test "stores the bytes under the prefix and returns the digest of the same bytes" do
      path = temp_upload("abc")

      for prefix <- ["documents", "statements"] do
        assert {:ok, %{object_key: object_key, filename: "bill.pdf", content_sha256: @abc_sha256}} =
                 Storage.store_upload(path, "bill.pdf", prefix)

        assert [^prefix, name] = String.split(object_key, "/")
        assert {:ok, _uuid} = name |> Path.rootname() |> Ecto.UUID.cast()
        assert Path.extname(name) == ".pdf"
        assert {:ok, "abc"} = Storage.read_object(object_key)
      end
    end

    test "stores nothing when the upload cannot be read" do
      missing = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}")

      assert {:error, :enoent} = Storage.store_upload(missing, "bill.pdf", "documents")
      assert [] = :ets.tab2list(Memory)
    end
  end

  defp temp_upload(bytes) do
    path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
