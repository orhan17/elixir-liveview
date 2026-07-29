defmodule Retro.Boards.Board do
  use Ecto.Schema
  import Ecto.Changeset

  schema "boards" do
    field :slug, :string
    field :title, :string

    has_many :cards, Retro.Boards.Card

    timestamps(type: :utc_datetime)
  end

  def changeset(board, attrs) do
    # |> is the pipe operator: it passes the left value as the FIRST argument of
    # the next call — `board |> cast(attrs, ...)` is `cast(board, attrs, ...)`.
    board
    |> cast(attrs, [:slug, :title])
    |> validate_required([:slug, :title])
    # ~r// is a sigil — literal syntax for a regex, like /.../ in PHP's preg_*.
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "only lowercase letters, digits and hyphens"
    )
    |> validate_length(:slug, min: 3, max: 40)
    |> validate_length(:title, max: 255)
    # Not a pre-SELECT: this converts the unique-index violation reported by
    # Postgres on INSERT into a changeset error — no check-then-act race.
    |> unique_constraint(:slug)
  end
end
