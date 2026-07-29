defmodule Retro.Repo.Migrations.CreateCards do
  use Ecto.Migration

  def change do
    create table(:cards) do
      # Cascade lives in the DB schema, not in application code: dropping a board
      # can never leave orphan cards, no matter which code path deletes it.
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      # "lane", not "column": avoids the SQL reserved word and the constant
      # board-column vs table-column ambiguity in conversation and ADRs.
      add :lane, :string, null: false
      add :body, :text, null: false
      add :author_name, :string, null: false
      # Float, not integer: inserting between two cards is one write (midpoint),
      # not a renumber-the-tail transaction. Known degradation after many
      # midpoint inserts into the same gap — accepted for retro-board scale (ADR).
      add :position, :float, null: false
      add :votes, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:cards, [:board_id])
  end
end
