defmodule VideoTool.Repo.Migrations.CreateAppState do
  use Ecto.Migration

  def change do
    # 앱 전역 상태 한 줄짜리들. 지금은 MCP 가 언제 붙었는지를 담는다.
    #
    # 메모리에만 두면 서버를 재시작할 때마다 "연결한 적 없음" 이 되어
    # 사용자를 다시 안내 화면에 가둔다.
    create table(:app_state, primary_key: false) do
      add :key, :string, size: 60, primary_key: true
      add :value, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end
  end
end