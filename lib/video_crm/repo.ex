defmodule VideoCRM.Repo do
  use Ecto.Repo,
    otp_app: :video_crm,
    adapter: Ecto.Adapters.Postgres
end
