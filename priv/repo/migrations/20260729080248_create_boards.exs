defmodule Retro.Repo.Migrations.CreateBoards do
  # `use` runs the module's __using__ macro at compile time, injecting the DSL
  # (create/add/timestamps) into this module — closer to a PHP trait than to an import.
  use Ecto.Migration

  def change do
    create table(:boards) do
      add :slug, :string, null: false
      add :title, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:boards, [:slug])
  end
end
