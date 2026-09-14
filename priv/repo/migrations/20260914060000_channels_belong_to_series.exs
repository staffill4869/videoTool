defmodule VideoTool.Repo.Migrations.ChannelsBelongToSeries do
  @moduledoc """
  발행 채널을 시리즈 밑으로 옮긴다.

  지금까지 채널은 설정 화면에 떠 있는 평평한 목록이었고, 시리즈는 `channel_slug` 문자열로
  그중 하나를 가리켰다. 그래서 "이 시리즈는 어디로 올라가나" 를 보려면 두 화면을 오가야 했고,
  시리즈마다 본채널·쇼츠 두 곳에 올리는 걸 표현할 자리가 없었다.

  `account_id` 유일 인덱스를 같이 건다 — **같은 유튜브 채널을 두 칸에 연결하면
  두 칸이 같은 곳으로 올라간다.** `videos.insert` 에는 채널을 지정하는 항목이 없어서
  토큰이 곧 채널이기 때문이다. 화면에서도 막지만 DB 가 마지막 방어선이다.
  """
  use Ecto.Migration

  def up do
    alter table(:channels) do
      add :series_id, references(:series, on_delete: :nilify_all)
      add :kind, :string, size: 20, null: false, default: "main"
    end

    create index(:channels, [:series_id])
    create unique_index(:channels, [:series_id, :kind], name: :channels_series_kind_index)

    # account_id 에 유일 인덱스를 걸려고 했으나 **기존 데이터가 이미 어긴다** —
    # yt-main·yt-supplement·yt-history·yt-cat 네 칸이 전부 같은 유튜브 채널
    # (UCCTXJSB46o23TkRQmIZ1sHg) 을 가리키고 있었다. 그래서 시리즈별로 다른 채널에
    # 올린다고 해 놓고 13편이 전부 한 채널로 갔다.
    #
    # 여기서 조용히 끊어 버리면 지금 돌고 있는 업로드가 멈춘다. 어느 칸이 그 채널을
    # 가질지는 사람이 정할 일이라, 마이그레이션은 손대지 않는다.
    # 대신 **새 연결은 코드가 막고**(GoogleOAuth.identify/2), 겹친 칸은 화면에 경고로 띄운다.

    # 이미 시리즈가 가리키던 채널을 그 시리즈의 본채널로 붙인다.
    execute """
    UPDATE channels c
       SET series_id = s.id, kind = 'main'
      FROM series s
     WHERE s.channel_slug = c.slug AND s.channel_slug <> ''
    """
  end

  def down do
    drop index(:channels, [:series_id, :kind], name: :channels_series_kind_index)
    drop index(:channels, [:series_id])

    alter table(:channels) do
      remove :series_id
      remove :kind
    end
  end
end
