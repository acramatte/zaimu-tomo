defmodule ZaimuTomo.Repo.Migrations.RenameDocumentsFilepathToObjectKey do
  use Ecto.Migration

  def up do
    rename table(:documents), :filepath, to: :object_key

    execute("""
    UPDATE documents
    SET object_key = 'documents/' || replace(object_key, '/uploads/', '')
    WHERE object_key LIKE '/uploads/%'
    """)
  end

  def down do
    execute("""
    UPDATE documents
    SET object_key = '/uploads/' || replace(object_key, 'documents/', '')
    WHERE object_key LIKE 'documents/%'
    """)

    rename table(:documents), :object_key, to: :filepath
  end
end
