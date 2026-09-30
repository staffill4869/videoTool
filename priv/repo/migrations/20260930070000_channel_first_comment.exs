defmodule VideoTool.Repo.Migrations.ChannelFirstComment do
  use Ecto.Migration

  # 올린 뒤 첫 댓글을 채널마다 다르게 쓴다. 지금까지는 upload.ex 에 박힌 문구
  # 하나를 세 채널이 같이 썼는데, 채널마다 하고 싶은 말이 다르다 —
  # 영양제는 프로필을 눌러 보라고 하고 싶고, 지원사업은 그럴 이유가 없다.
  #
  # 비워 두면 upload.ex 의 기본 문구가 나간다.
  def change do
    alter table(:channels) do
      add :first_comment, :text, null: false, default: ""
    end
  end
end
