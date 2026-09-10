defmodule VideoCRM.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VideoCRMWeb.Telemetry,
      VideoCRM.Repo,
      # Flow 자동 조종을 백그라운드로 돌린다 (Veo 가 분 단위라 요청을 붙잡을 수 없다)
      {Task.Supervisor, name: VideoCRM.TaskSupervisor},
      # 시리즈: 간격마다 프로젝트를 만든다 (제작만. 발행은 사람이 누른다)
      VideoCRM.Series.Runner,
      {DNSCluster, query: Application.get_env(:video_crm, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: VideoCRM.PubSub},
      # Start a worker by calling: VideoCRM.Worker.start_link(arg)
      # {VideoCRM.Worker, arg},
      # Start to serve requests, typically the last entry
      VideoCRMWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: VideoCRM.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VideoCRMWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
