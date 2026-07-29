defmodule Retro.BoardServerTest do
  use Retro.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Retro.BoardFixtures

  alias Retro.{BoardServer, Boards, Repo}
  alias Retro.Boards.Card

  defp server_pid(slug) do
    [{pid, _}] = Registry.lookup(Retro.BoardRegistry, slug)
    pid
  end

  defp kill_server(slug) do
    pid = server_pid(slug)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    pid
  end

  describe "lifecycle" do
    test "start_or_lookup is race-safe: concurrent callers share one pid" do
      board = board_fixture()

      pids =
        1..8
        |> Task.async_stream(fn _ -> BoardServer.start_or_lookup(board.slug) end)
        |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

      assert [_single] = Enum.uniq(pids)
    end

    test "init hydrates existing cards from Postgres" do
      board = board_fixture()

      # write directly to the DB — the server must pick these up on boot
      Repo.insert_all(Card, [
        %{board_id: board.id, lane: :went_well, body: "from db", author_name: "x",
          position: 1.0, votes: 3,
          inserted_at: DateTime.truncate(DateTime.utc_now(), :second),
          updated_at: DateTime.truncate(DateTime.utc_now(), :second)}
      ])

      assert [%Card{body: "from db", votes: 3, lane: :went_well}] = Boards.list_cards(board)
    end
  end

  describe "write-behind" do
    test "a create is visible immediately but reaches Postgres only on flush" do
      board = board_fixture()
      card = card_fixture(board, %{"body" => "buffered"})

      assert [%{body: "buffered"}] = Boards.list_cards(board)
      refute Repo.get(Card, card.id), "must not be in the DB before the flush"

      :ok = BoardServer.flush(board.slug)
      assert %Card{body: "buffered"} = Repo.get(Card, card.id)
    end

    test "ids come from the DB sequence even though the insert is deferred" do
      board = board_fixture()
      card = card_fixture(board)
      assert is_integer(card.id)

      :ok = BoardServer.flush(board.slug)
      assert Repo.get(Card, card.id)
    end

    test "the flush is an upsert: mutations after a flush overwrite the row" do
      board = board_fixture()
      card = card_fixture(board, %{"body" => "v1"})
      :ok = BoardServer.flush(board.slug)

      {:ok, _} = Boards.update_card(board, card.id, %{"body" => "v2"}, "Fixture")
      {:ok, _} = Boards.vote_card(board, card.id)
      :ok = BoardServer.flush(board.slug)

      assert %Card{body: "v2", votes: 1} = Repo.get(Card, card.id)
    end

    test "a delete reaches Postgres as a DELETE on flush" do
      board = board_fixture()
      card = card_fixture(board)
      :ok = BoardServer.flush(board.slug)
      assert Repo.get(Card, card.id)

      {:ok, _} = Boards.delete_card(board, card.id)
      :ok = BoardServer.flush(board.slug)
      refute Repo.get(Card, card.id)
    end

    test "create-then-delete within one window never touches the DB" do
      board = board_fixture()
      card = card_fixture(board)
      {:ok, _} = Boards.delete_card(board, card.id)

      :ok = BoardServer.flush(board.slug)
      refute Repo.get(Card, card.id)
      assert Repo.aggregate(from(c in Card, where: c.board_id == ^board.id), :count) == 0
    end
  end

  describe "failure semantics — the honest part" do
    test "kill loses exactly the unflushed window, nothing more" do
      board = board_fixture()
      durable = card_fixture(board, %{"body" => "durable"})
      :ok = BoardServer.flush(board.slug)
      lost = card_fixture(board, %{"body" => "lost"})

      kill_server(board.slug)

      bodies = board |> Boards.list_cards() |> Enum.map(& &1.body)
      assert bodies == ["durable"]
      assert Repo.get(Card, durable.id)
      refute Repo.get(Card, lost.id)
    end

    test "a killed server is restarted by the supervisor with a fresh pid" do
      board = board_fixture()
      # create_board is Repo-only — touch the board so its server exists
      assert Boards.list_cards(board) == []
      old_pid = kill_server(board.slug)

      # the next touch either finds the restarted server or revives it
      assert Boards.list_cards(board) == []
      assert server_pid(board.slug) != old_pid
    end

    test "graceful termination flushes: terminate/2 runs on supervisor shutdown" do
      board = board_fixture()
      card = card_fixture(board, %{"body" => "saved by terminate"})
      refute Repo.get(Card, card.id)

      :ok = DynamicSupervisor.terminate_child(Retro.BoardSupervisor, server_pid(board.slug))

      assert %Card{body: "saved by terminate"} = Repo.get(Card, card.id)
    end

    test "idle shutdown flushes, stays down (:transient + :normal), revives on touch" do
      board = board_fixture()
      card = card_fixture(board, %{"body" => "sleepy"})
      refute Repo.get(Card, card.id)

      pid = server_pid(board.slug)
      ref = Process.monitor(pid)
      :sys.replace_state(pid, fn s -> %{s | last_activity: s.last_activity - 11 * 60_000} end)
      send(pid, :idle_check)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      assert Repo.get(Card, card.id), "the way out must flush"
      assert Registry.lookup(Retro.BoardRegistry, board.slug) == []

      assert [%{body: "sleepy"}] = Boards.list_cards(board)
      assert server_pid(board.slug) != pid
    end
  end
end
