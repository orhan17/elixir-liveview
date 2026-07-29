defmodule Retro.Boards.Card do
  use Ecto.Schema
  import Ecto.Changeset

  # @lanes is a module attribute — a compile-time constant, closer to a Go
  # const than to a PHP static property.
  @lanes [:went_well, :to_improve, :action_items]

  schema "cards" do
    # Ecto.Enum casts these atoms to strings on write and back to atoms on
    # read; any value outside @lanes fails the cast with "is invalid".
    field :lane, Ecto.Enum, values: @lanes
    field :body, :string
    field :author_name, :string
    field :position, :float
    field :votes, :integer, default: 0

    belongs_to :board, Retro.Boards.Board

    timestamps(type: :utc_datetime)
  end

  # `do:` is the single-line form of a function body.
  def lanes, do: @lanes

  # defguard defines a reusable guard expression (guards are a restricted
  # compile-time language — no arbitrary function calls allowed, which is why
  # `lane in Card.lanes()` cannot appear in a `when` clause, but `in @lanes`
  # can: the attribute inlines at compile time). Callers `import` this and get
  # the lane check right in the function head.
  defguard is_lane(lane) when lane in @lanes

  # THE single definition of card ordering; the SQL order_by in
  # Retro.Boards.list_cards/1 is its mirror — change them only as a pair.
  # Lane compares as a string because that is exactly how Postgres orders the
  # varchar column (cross-lane order is grouping only; the UI renders lanes as
  # separate containers). `__MODULE__` is the current module, i.e. Card.
  def sort_key(%__MODULE__{} = card), do: {Atom.to_string(card.lane), card.position, card.id}

  # :votes and :position are deliberately NOT in cast/3: whatever is listed
  # there is client-writable. Votes become a separate BoardServer operation
  # (Phase 6); position is computed by the context, never taken from input.
  def changeset(card, attrs) do
    card
    |> cast(attrs, [:lane, :body, :author_name])
    # &String.trim/1 captures an existing function as a value (Go: method value).
    # Trim runs BEFORE validations, so "   " becomes "" => "can't be blank".
    |> update_change(:body, &String.trim/1)
    |> validate_required([:lane, :body, :author_name])
    |> validate_length(:body, min: 1, max: 500)
    |> validate_length(:author_name, min: 1, max: 60)
    |> foreign_key_constraint(:board_id)
  end
end
