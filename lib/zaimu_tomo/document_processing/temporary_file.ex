defmodule ZaimuTomo.DocumentProcessing.TemporaryFile do
  @moduledoc false

  @directory_name "zaimu-tomo"
  @directory_mode 0o700
  @file_mode 0o600

  @spec create(String.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def create(object_key) do
    directory = Path.join(System.tmp_dir!(), @directory_name)
    path = Path.join(directory, "#{Ecto.UUID.generate()}#{Path.extname(object_key)}")

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, @directory_mode),
         {:ok, file} <- File.open(path, [:write, :exclusive, :binary]),
         :ok <- File.close(file),
         :ok <- File.chmod(path, @file_mode) do
      {:ok, path}
    else
      {:error, _reason} = error ->
        File.rm(path)
        error
    end
  end
end
