defmodule VideoTool.Repo do
  use Ecto.Repo,
    otp_app: :video_tool,
    adapter: Ecto.Adapters.Postgres
end
