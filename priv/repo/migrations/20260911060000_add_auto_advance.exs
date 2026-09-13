defmodule VideoTool.Repo.Migrations.AddAutoAdvance do
  use Ecto.Migration

  def change do
    alter table(:series) do
      # 켜면 서버가 대본이 채워진 프로젝트를 스스로 다음 단계로 민다 (Flow 생성까지).
      # 기본은 꺼둔다 — 켜는 순간 사람 없이 크레딧이 나가기 시작한다.
      add :auto_advance, :boolean, null: false, default: false
    end
  end
end
