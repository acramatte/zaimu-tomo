defmodule ZaimuTomo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    ZaimuTomo.Langfuse.setup()

    children = [
      ZaimuTomoWeb.Telemetry,
      ZaimuTomo.Repo,
      {DNSCluster, query: Application.get_env(:zaimu_tomo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ZaimuTomo.PubSub},
      # Start a worker by calling: ZaimuTomo.Worker.start_link(arg)
      # {ZaimuTomo.Worker, arg},
      # Start to serve requests, typically the last entry
      ZaimuTomoWeb.Endpoint,
      ZaimuTomo.DocumentProcessing.Saga,
      {ZaimuTomo.DocumentProcessing.OCRSupervisor, name: ZaimuTomo.OCRSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ZaimuTomo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ZaimuTomoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
