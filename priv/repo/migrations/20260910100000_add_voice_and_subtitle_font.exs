defmodule VideoTool.Repo.Migrations.AddVoiceAndSubtitleFont do
  use Ecto.Migration

  def up do
    # 보이스를 고르려면 들어봐야 한다. 힉스필드가 주는 미리듣기 주소를 그대로 들고 있는다.
    alter table(:voices) do
      add :preview_url, :string, null: false, default: ""
      add :gender, :string, size: 10, null: false, default: ""
      # 낭독 속도. 0 이 보통이고 여기서 손대지 않는다 —
      # 길이가 안 맞으면 속도를 올리는 게 아니라 대본을 고친다.
      add :speech_rate, :float, null: false, default: 0.0
    end

    # 자막 폰트는 프롬프트가 아니라 실제 ffmpeg/ASS 설정이다.
    # 이 PC 에 깔려 있지 않은 폰트를 넣으면 글자가 두부(□)로 나온다.
    alter table(:projects) do
      add :subtitle_font, :string, size: 60, null: false, default: ""
    end

    alter table(:series) do
      add :subtitle_font, :string, size: 60, null: false, default: ""
      add :voice_speech_rate, :float, null: false, default: 0.0
    end
  end

  def down do
    alter table(:voices) do
      remove :preview_url
      remove :gender
      remove :speech_rate
    end

    alter table(:projects), do: remove(:subtitle_font)

    alter table(:series) do
      remove :subtitle_font
      remove :voice_speech_rate
    end
  end
end
