defmodule VideoTool.Repo.Migrations.SeriesCharacters do
  use Ecto.Migration

  # Flow 에 등록해 둔 **캐릭터 이름**. 생성할 때마다 프롬프트에 붙여 같은 인물이 나오게 한다.
  # 글로 외모를 적는 것으로는 안 됐다 — 머리·안경·옷 색까지 못 박아도 매 편 다른 사람이 나왔다.
  def change do
    alter table(:series) do
      add :flow_characters, {:array, :string}, null: false, default: []
    end
  end
end
