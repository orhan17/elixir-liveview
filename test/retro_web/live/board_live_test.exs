defmodule RetroWeb.BoardLiveTest do
  use RetroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Retro.BoardFixtures

  alias Retro.Boards

  defp join(conn, name), do: Plug.Test.init_test_session(conn, %{"display_name" => name})

  defp mount_pair(conn, board) do
    {:ok, view_a, _} = live(join(conn, "Alice"), "/b/#{board.slug}")
    {:ok, view_b, _} = live(join(Phoenix.ConnTest.build_conn(), "Bob"), "/b/#{board.slug}")
    {view_a, view_b}
  end

  # Presence diffs land asynchronously; poll the rendered HTML briefly
  # instead of sleeping a fixed amount.
  defp eventually(fun, attempts \\ 50) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("condition not met in time")
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  describe "mount and join flow" do
    test "redirects to the join form when the session has no name", %{conn: conn} do
      board = board_fixture()
      assert {:error, {:redirect, %{to: to}}} = live(conn, "/b/#{board.slug}")
      assert to == "/b/#{board.slug}/join"
    end

    test "join form stores the name in the session and redirects to the board", %{conn: conn} do
      board = board_fixture()
      conn = post(conn, "/b/#{board.slug}/join", %{"display_name" => "  Carol  "})
      assert redirected_to(conn) == "/b/#{board.slug}"
      assert Plug.Conn.get_session(conn, :display_name) == "Carol"
    end

    test "unknown slug 404s", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(join(conn, "Alice"), "/b/no-such-board") end
    end

    test "mount renders title, all three lanes and existing cards", %{conn: conn} do
      board = board_fixture(%{title: "Sprint 99"})
      card_fixture(board, %{"body" => "pre-existing"})

      {:ok, _view, html} = live(join(conn, "Alice"), "/b/#{board.slug}")
      assert html =~ "Sprint 99"
      assert html =~ "Went well"
      assert html =~ "To improve"
      assert html =~ "Action items"
      assert html =~ "pre-existing"
      assert html =~ "You are Alice"
    end
  end

  describe "creating cards" do
    test "render_submit adds a card attributed to the session name", %{conn: conn} do
      board = board_fixture()
      {:ok, view, _} = live(join(conn, "Alice"), "/b/#{board.slug}")

      view
      |> form("#card-form-went_well", card: %{body: "my first card", lane: "went_well"})
      |> render_submit()

      html = render(view)
      assert html =~ "my first card"
      assert html =~ "Alice"
      assert [%{author_name: "Alice", body: "my first card"}] = Boards.list_cards(board)
    end

    test "an invalid submit shows the error and stores nothing", %{conn: conn} do
      board = board_fixture()
      {:ok, view, _} = live(join(conn, "Alice"), "/b/#{board.slug}")

      html =
        view
        |> form("#card-form-went_well", card: %{body: "   ", lane: "went_well"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Boards.list_cards(board) == []
    end
  end

  describe "two clients" do
    test "a card submitted by A is rendered by B (the PubSub acceptance test)", %{conn: conn} do
      board = board_fixture()
      {view_a, view_b} = mount_pair(conn, board)

      view_a
      |> form("#card-form-to_improve", card: %{body: "broadcast me", lane: "to_improve"})
      |> render_submit()

      assert render(view_b) =~ "broadcast me"

      assert render(view_a) =~ "broadcast me",
             "the author's own tab renders via the same broadcast"
    end

    test "votes propagate", %{conn: conn} do
      board = board_fixture()
      card = card_fixture(board)
      {view_a, view_b} = mount_pair(conn, board)

      view_a |> element("button[phx-click=vote][phx-value-id=\"#{card.id}\"]") |> render_click()

      assert render(view_b) =~ "▲ 1"
      assert render(view_a) =~ "▲ 1"
    end

    test "author's edit propagates; non-author gets no edit button", %{conn: conn} do
      board = board_fixture()
      card = card_fixture(board, %{"author_name" => "Alice", "body" => "draft wording"})
      {view_a, view_b} = mount_pair(conn, board)

      refute view_b
             |> element("button[phx-click=edit_card][phx-value-id=\"#{card.id}\"]")
             |> has_element?()

      view_a
      |> element("button[phx-click=edit_card][phx-value-id=\"#{card.id}\"]")
      |> render_click()

      view_a
      |> form("#edit-form-#{card.id}", card: %{body: "final wording"})
      |> render_submit()

      assert render(view_b) =~ "final wording"
      refute render(view_b) =~ "draft wording"
    end

    test "a drag reported by A reorders B", %{conn: conn} do
      board = board_fixture()
      # distinctive bodies: plain words like "first" collide with CSS
      # classes (first:ml-0) when searching the rendered HTML
      c1 = card_fixture(board, %{"body" => "aardvark"})
      _c2 = card_fixture(board, %{"body" => "zephyr"})
      {view_a, view_b} = mount_pair(conn, board)

      view_a
      |> element("#cards-went_well")
      |> render_hook("reposition", %{
        "id" => to_string(c1.id),
        "lane" => "went_well",
        "new_index" => 1
      })

      html = render(view_b)
      {pos_zephyr, _} = :binary.match(html, "zephyr")
      {pos_aardvark, _} = :binary.match(html, "aardvark")
      assert pos_zephyr < pos_aardvark
    end

    test "typing indicator shows for the other client only", %{conn: conn} do
      board = board_fixture()
      {view_a, view_b} = mount_pair(conn, board)

      view_a
      |> form("#card-form-went_well", card: %{body: "draf", lane: "went_well"})
      |> render_change()

      assert render(view_b) =~ "Alice is typing"
      refute render(view_a) =~ "Alice is typing"
    end

    test "presence: roster shows both, shrinks when one dies", %{conn: conn} do
      board = board_fixture()
      {view_a, view_b} = mount_pair(conn, board)

      eventually(fn -> render(view_a) =~ "2 online" end)

      # the test process is linked to the client proxy — trap the exit so
      # killing B's LiveView doesn't take the test down with it
      Process.flag(:trap_exit, true)
      Process.exit(view_b.pid, :kill)

      eventually(fn -> render(view_a) =~ "1 online" end)
    end
  end
end
