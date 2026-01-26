defmodule Ledgemechanicus.Repo.Migrations.RefactorDocumentWithFilenameUrlOnly do
  use Ecto.Migration

  def change do
    rename table(:documents), :title, to: :filename
    rename table(:documents), :url, to: :filepath
    alter table(:documents) do
      remove :description
    end
  end

end
