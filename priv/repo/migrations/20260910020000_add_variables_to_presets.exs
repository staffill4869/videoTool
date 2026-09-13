defmodule VideoTool.Repo.Migrations.AddVariablesToPresets do
  use Ecto.Migration

  def change do
    # 프롬프트에서 바꿔 끼울 값들. "고품질 3D 렌더링", "8초", "3~4초" 처럼
    # 바꾸면 다른 영상이 나오는 칸을 이름 붙여 담는다.
    #
    # 컬럼을 하나씩 늘리지 않는 이유: 어떤 칸이 필요할지는 프롬프트를 고쳐 보면서 알게 된다.
    # 새 칸이 생길 때마다 마이그레이션을 돌려야 하면 결국 안 고치게 된다.
    alter table(:style_presets) do
      add :variables, :map, null: false, default: %{}
    end

    alter table(:domain_presets) do
      add :variables, :map, null: false, default: %{}
    end
  end
end