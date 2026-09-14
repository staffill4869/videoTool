defmodule VideoToolWeb.Router do
  use VideoToolWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VideoToolWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", VideoToolWeb do
    pipe_through :browser

    # 게이트 밖 — 연결이 안 되는 원인을 고치려면 이 둘은 들어갈 수 있어야 한다.
    live "/connect", ConnectLive, :index
    live "/settings", SettingsLive, :index

    # 이 앱의 조작은 전부 MCP 로 한다. 한 번도 안 붙었으면 /connect 로 보낸다.
    live_session :gated, on_mount: {VideoToolWeb.RequireMCP, :default} do
      live "/", ProjectLive.Index, :index
      live "/projects", ProjectLive.Index, :index
      live "/projects/:id", ProjectLive.Show, :show
      live "/dashboard", DashboardLive, :index
      live "/series", SeriesLive, :index
      live "/prompts", PromptLive, :index
      live "/voices", VoiceLive, :index
      live "/channels", ChannelLive, :index
    end

    # 구글 동의 화면에서 돌아오는 곳 (데스크톱 앱 클라이언트라 루프백을 쓴다)
    get "/oauth/google/callback", OAuthController, :google_callback

    # 자산 미리보기. 작업 폴더 밖의 경로는 내주지 않는다.
    get "/assets/:id/preview", AssetController, :preview
    get "/renders/:id/play", RenderController, :play
  end

  # 에이전트(Claude / Codex)가 붙는 MCP 엔드포인트.
  # Tidewave 는 /tidewave/mcp 에서 개발용 툴을, 여기는 /mcp 에서 이 앱의 툴을 준다.
  scope "/", VideoToolWeb do
    pipe_through :api

    post "/mcp", MCPController, :handle
  end

  # REST 창구. MCP 로 되는 일을 HTTP 로도 열어둔다.
  scope "/api", VideoToolWeb do
    pipe_through :api

    # 에이전트 작업 큐 — 붙어 있는 동안 이것만 반복해 부르면 계속 일한다
    get "/work/next", ApiController, :next_job
    get "/work/jobs", ApiController, :jobs
    get "/work/summary", ApiController, :summary

    get "/projects", ApiController, :list_projects
    post "/projects", ApiController, :create_project
    get "/projects/:id", ApiController, :get_project
    patch "/projects/:id", ApiController, :update_project
    put "/projects/:id", ApiController, :update_project
    delete "/projects/:id", ApiController, :delete_project

    # 같은 영상의 다른 언어판 — CLEAN 은 원본 것을 재사용한다
    get "/languages", ApiController, :languages
    get "/projects/:id/variants", ApiController, :list_variants
    post "/projects/:id/variants", ApiController, :create_variant

    get "/projects/:id/prompt/:stage", ApiController, :get_prompt
    put "/projects/:id/prompt/:stage", ApiController, :put_prompt
    delete "/projects/:id/prompt/:stage", ApiController, :delete_prompt

    get "/series", ApiController, :list_series
    post "/series", ApiController, :create_series
    get "/series/:id", ApiController, :get_series
    patch "/series/:id", ApiController, :update_series
    put "/series/:id", ApiController, :update_series
    delete "/series/:id", ApiController, :delete_series
    post "/series/:id/run", ApiController, :run_series

    # MCP 툴을 그대로 부른다. 두 벌로 구현하지 않기 위해서다.
    get "/dashboard", ApiController, :dashboard
    post "/dashboard/collect", ApiController, :collect_metrics
    post "/publications/:id/metrics", ApiController, :record_metrics
    get "/publications/:id/metrics", ApiController, :metric_history

    get "/tools", ApiController, :tools
    post "/tools/:name", ApiController, :call_tool
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:video_tool, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: VideoToolWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
