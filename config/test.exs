import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :video_crm, VideoCRM.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "video_crm_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :video_crm, VideoCRMWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "i51rsbw7daTIdLoQawMmUZ4fEVqedTs2Lkh7/szpaCrwM8Skiz3PItsVtehzV3/d",
  server: false

# In test we don't send emails
config :video_crm, VideoCRM.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# 테스트가 사용자 클립보드를 덮어쓰지 않게 한다.
config :video_crm, :clipboard, VideoCRM.Clipboard.Noop

# 테스트가 실제 브라우저에 좌우되지 않게 한다.
config :video_crm, :flow, VideoCRM.FlowStub

# 테스트 도중에 프로젝트가 저절로 생기면 안 된다.
config :video_crm, :series_runner, false
