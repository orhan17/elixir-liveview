defmodule Retro.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :retro

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  # One-shot boot task for the dockerized demo: migrate, then make sure the
  # /b/demo board exists so a reviewer has something to click. Idempotent.
  def setup do
    migrate()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _repo -> ensure_demo_board() end)
    end
  end

  defp ensure_demo_board do
    alias Retro.Boards.Board

    unless Retro.Repo.get_by(Board, slug: "demo") do
      %Board{}
      |> Board.changeset(%{slug: "demo", title: "Demo Retro"})
      |> Retro.Repo.insert!()
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
