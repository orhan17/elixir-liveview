defmodule Retro.BoardsTest do
  # async: false — card operations go through globally registered BoardServer
  # processes, which need the shared DB sandbox.
  use Retro.DataCase, async: false

  import Retro.BoardFixtures

  alias Retro.Boards
  alias Retro.Boards.{Board, Card}

  describe "board changeset / create_board" do
    test "creates a board with a valid slug and title" do
      assert {:ok, %Board{slug: "retro-42"}} =
               Boards.create_board(%{slug: "retro-42", title: "Sprint 42"})
    end

    test "rejects malformed slugs" do
      for bad <- ["UPPER", "with space", "sla$h", "ы"] do
        assert {:error, changeset} = Boards.create_board(%{slug: bad, title: "t"})
        assert "only lowercase letters, digits and hyphens" in errors_on(changeset).slug
      end
    end

    test "rejects slugs outside 3..40 chars" do
      assert {:error, changeset} = Boards.create_board(%{slug: "ab", title: "t"})
      assert %{slug: [_]} = errors_on(changeset)

      long = String.duplicate("a", 41)
      assert {:error, changeset} = Boards.create_board(%{slug: long, title: "t"})
      assert %{slug: [_]} = errors_on(changeset)
    end

    test "requires slug and title" do
      assert {:error, changeset} = Boards.create_board(%{})
      assert %{slug: ["can't be blank"], title: ["can't be blank"]} = errors_on(changeset)
    end

    test "slug uniqueness is enforced by the database, not a pre-check" do
      {:ok, _} = Boards.create_board(%{slug: "taken-slug", title: "first"})
      assert {:error, changeset} = Boards.create_board(%{slug: "taken-slug", title: "second"})
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "card changeset" do
    test "requires lane, body and author_name" do
      changeset = Boards.change_card(%Card{}, %{})
      assert %{lane: [_], body: [_], author_name: [_]} = errors_on(changeset)
    end

    test "rejects a lane outside the enum" do
      changeset =
        Boards.change_card(%Card{}, %{"lane" => "breakfast", "body" => "b", "author_name" => "a"})

      assert %{lane: ["is invalid"]} = errors_on(changeset)
    end

    test "trims body before validating, so whitespace-only is blank" do
      changeset =
        Boards.change_card(%Card{}, %{
          "lane" => "went_well",
          "body" => "   ",
          "author_name" => "a"
        })

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects body over 500 chars" do
      changeset =
        Boards.change_card(%Card{}, %{
          "lane" => "went_well",
          "body" => String.duplicate("x", 501),
          "author_name" => "a"
        })

      assert %{body: [_]} = errors_on(changeset)
    end

    test "votes and position are not client-writable" do
      changeset =
        Boards.change_card(%Card{}, %{
          "lane" => "went_well",
          "body" => "b",
          "author_name" => "a",
          "votes" => 999,
          "position" => 0.0
        })

      refute Map.has_key?(changeset.changes, :votes)
      refute Map.has_key?(changeset.changes, :position)
    end
  end

  describe "card CRUD through the context" do
    setup do
      %{board: board_fixture()}
    end

    test "create_card appends positions per lane", %{board: board} do
      c1 = card_fixture(board, %{"lane" => "went_well"})
      c2 = card_fixture(board, %{"lane" => "went_well"})
      c3 = card_fixture(board, %{"lane" => "to_improve"})

      assert c1.position == 1.0
      assert c2.position == 2.0
      assert c3.position == 1.0, "each lane counts positions independently"
    end

    test "create_card with an invalid payload returns the changeset and stores nothing",
         %{board: board} do
      assert {:error, %Ecto.Changeset{valid?: false}} =
               Boards.create_card(board, %{"body" => "x"})

      assert Boards.list_cards(board) == []
    end

    test "list_cards orders by lane (as string), position, id", %{board: board} do
      ww = card_fixture(board, %{"lane" => "went_well", "body" => "ww"})
      ai = card_fixture(board, %{"lane" => "action_items", "body" => "ai"})
      ti = card_fixture(board, %{"lane" => "to_improve", "body" => "ti"})

      assert Enum.map(Boards.list_cards(board), & &1.id) == [ai.id, ti.id, ww.id],
             "action_items < to_improve < went_well alphabetically"
    end

    test "update_card lets the author edit and refuses everyone else", %{board: board} do
      card = card_fixture(board, %{"author_name" => "Alice"})

      assert {:ok, %Card{body: "edited"}} =
               Boards.update_card(board, card.id, %{"body" => "edited"}, "Alice")

      assert {:error, :forbidden} = Boards.update_card(board, card.id, %{"body" => "nope"}, "Bob")
      assert [%{body: "edited"}] = Boards.list_cards(board)
    end

    test "update_card on a missing id is :not_found", %{board: board} do
      assert {:error, :not_found} = Boards.update_card(board, 999_999, %{"body" => "x"}, "Alice")
    end

    test "vote_card increments votes", %{board: board} do
      card = card_fixture(board)
      {:ok, _} = Boards.vote_card(board, card.id)
      assert {:ok, %Card{votes: 2}} = Boards.vote_card(board, card.id)
    end

    test "delete_card removes the card", %{board: board} do
      card = card_fixture(board)
      assert {:ok, _} = Boards.delete_card(board, card.id)
      assert Boards.list_cards(board) == []
      assert {:error, :not_found} = Boards.delete_card(board, card.id)
    end

    test "reposition_card drops between neighbours at half distance", %{board: board} do
      c1 = card_fixture(board, %{"body" => "first"})
      c2 = card_fixture(board, %{"body" => "second"})
      c3 = card_fixture(board, %{"body" => "third"})

      # move third (3.0) to index 0: before first (1.0) -> 0.5
      assert {:ok, %Card{position: 0.5}} =
               Boards.reposition_card(board, c3.id, :went_well, 0)

      # move first between second's old neighbours: index 2 of [third, second] -> append
      assert {:ok, %Card{position: 3.0}} = Boards.reposition_card(board, c1.id, :went_well, 2)

      assert Enum.map(Boards.list_cards(board), & &1.id) == [c3.id, c2.id, c1.id]
    end

    test "reposition_card into an empty lane lands on 1.0", %{board: board} do
      card = card_fixture(board)

      assert {:ok, %Card{lane: :action_items, position: 1.0}} =
               Boards.reposition_card(board, card.id, :action_items, 0)
    end

    test "reposition_card guards reject garbage in the caller's process", %{board: board} do
      card = card_fixture(board)

      assert_raise FunctionClauseError, fn ->
        Boards.reposition_card(board, card.id, :breakfast, 0)
      end

      assert_raise FunctionClauseError, fn ->
        Boards.reposition_card(board, card.id, :went_well, -1)
      end
    end
  end
end
