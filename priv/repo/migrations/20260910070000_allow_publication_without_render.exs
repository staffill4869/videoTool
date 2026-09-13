defmodule VideoTool.Repo.Migrations.AllowPublicationWithoutRender do
  use Ecto.Migration

  def change do
    # 이 시스템 밖에서 손으로 올린 영상을 등록하려면 렌더가 없을 수 있다.
    # 성과 집계를 하려면 그런 것도 발행물로 받아야 한다.
    execute "ALTER TABLE publications ALTER COLUMN render_id DROP NOT NULL",
            "ALTER TABLE publications ALTER COLUMN render_id SET NOT NULL"
  end
end