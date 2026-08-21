defmodule ZaimuTomo.DocumentProcessing.TemporaryFileTest do
  use ExUnit.Case, async: false

  alias ZaimuTomo.DocumentProcessing.TemporaryFile

  import Bitwise, only: [band: 2]

  test "creates a private file in the application scratch directory" do
    assert {:ok, path} = TemporaryFile.create("documents/invoice.pdf")
    on_exit(fn -> File.rm(path) end)

    assert Path.dirname(path) == Path.join(System.tmp_dir!(), "zaimu-tomo")
    assert Path.extname(path) == ".pdf"

    assert {:ok, file_stat} = File.stat(path)
    assert {:ok, directory_stat} = File.stat(Path.dirname(path))
    assert band(file_stat.mode, 0o777) == 0o600
    assert band(directory_stat.mode, 0o777) == 0o700
  end
end
