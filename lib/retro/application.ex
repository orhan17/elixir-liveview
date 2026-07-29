defmodule Retro.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RetroWeb.Telemetry,
      Retro.Repo,
      {DNSCluster, query: Application.get_env(:retro, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Retro.PubSub},
      # Presence must start after the PubSub it rides on and before the
      # Endpoint that produces the processes it tracks.
      RetroWeb.Presence,
      # Board processes: Registry maps slug -> pid, DynamicSupervisor starts
      # BoardServers on demand and restarts crashed ones. Before the Endpoint
      # for the same reason Presence is: traffic must arrive last.
      {Registry, keys: :unique, name: Retro.BoardRegistry},
      {DynamicSupervisor, name: Retro.BoardSupervisor, strategy: :one_for_one},
      # Start to serve requests, typically the last entry
      RetroWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Retro.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RetroWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
