defmodule VideoTool.Repo.Migrations.VoicesElevenId do
  use Ecto.Migration

  # 목소리 표와 실제 나레이션이 따로 놀고 있었다.
  #
  # `voices.voice_id` 에 든 것은 **힉스필드 UUID** 인데, 나레이션은 일레븐랩스로 만든다.
  # 두 체계가 안 맞아서 `generate_narration` 이 프로젝트 설정을 못 쓰고,
  # 에이전트가 그때그때 넣는 id 로 읽혔다 — 실측(2026-09-30, 2시간 로그):
  # pNInz6obpgDQGcFmaJgB(영어 Adam) 3회, 힉스필드 UUID 2회. 편마다 목소리가 달랐고,
  # 한국어 대본을 영어 목소리로 읽은 편이 그대로 발행됐다.
  #
  # 일레븐랩스 id 를 따로 담아 두고 그걸 먼저 쓴다.
  def change do
    alter table(:voices) do
      add :eleven_voice_id, :string, size: 64, null: false, default: ""
    end
  end
end
