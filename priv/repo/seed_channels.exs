# mix run priv/repo/seed_channels.exs
#
# 시리즈마다 올릴 유튜브 채널을 따로 둔다.
#
# 토큰은 `credential_ref` 경로에 저장된다. 그래서 두 행이 같은 ref 를 쓰면 **같은 채널**이다 —
# 실제로 yt-main 과 yt-shorts 가 둘 다 `videoCRM/youtube/yt-main` 이라, 하나를 연결하면
# 둘 다 같은 채널로 올라갔다. 행마다 ref 를 따로 줘야 채널이 갈린다.
#
# 행을 만든 뒤에는 **행마다 따로 로그인해야 한다.** 동의 화면에서 그 채널을 가진
# 계정(브랜드 계정이면 그 채널)을 고르면 그 행에만 토큰이 저장된다:
#
#   login_channel(channel_slug: "yt-supplement")   → 동의 → channel_status 로 확인
#   login_channel(channel_slug: "yt-history")
#   login_channel(channel_slug: "yt-cat")

import Ecto.Query
alias VideoTool.Repo
alias VideoTool.Publishing
alias VideoTool.Publishing.Channel

# 1. 같은 토큰을 쓰던 행을 갈라 놓는다.
Repo.update_all(
  from(c in Channel, where: c.slug == "yt-shorts"),
  set: [credential_ref: "videoCRM/youtube/yt-shorts"]
)

# 2. 시리즈별 채널. 쇼츠 규격(9:16, 3분 이내)으로 둔다 — 지금 만드는 영상이 그 규격이다.
#    공개 범위는 private 이 기본이다. 되돌릴 수 없는 행위의 기본값은 '안 보이게' 다.
channels = [
  {"yt-supplement", "영양제 채널", ["영양제", "건강", "쇼츠"]},
  {"yt-history", "역사 채널", ["역사", "잡학", "쇼츠"]},
  {"yt-cat", "고양이 채널", ["고양이", "반려동물", "쇼츠"]}
]

for {slug, name, tags} <- channels do
  attrs = %{
    platform: "youtube",
    slug: slug,
    display_name: name,
    credential_ref: "videoCRM/youtube/#{slug}",
    aspect_required: "9:16",
    max_duration_sec: 180,
    default_privacy: "private",
    default_hashtags: tags,
    is_active: true
  }

  case Publishing.fetch_channel(slug) do
    {:ok, existing} ->
      {:ok, _} = Publishing.update_channel(existing, Map.drop(attrs, [:slug, :platform]))
      IO.puts("#{slug}: 갱신")

    _ ->
      {:ok, _} = Publishing.create_channel(attrs)
      IO.puts("#{slug}: 만듦")
  end
end

# 3. 시리즈 → 채널 연결. 이름으로 고른다 — 시리즈 id 는 환경마다 다르다.
links = [
  {"영양제", "yt-supplement"},
  {"역사", "yt-history"},
  {"고양이", "yt-cat"}
]

for {keyword, slug} <- links do
  {n, _} =
    Repo.update_all(
      from(s in "series", where: like(s.name, ^"%#{keyword}%")),
      set: [channel_slug: slug]
    )

  IO.puts("시리즈 '#{keyword}' #{n}개 → #{slug}")
end

IO.puts("\n다음: 행마다 따로 로그인해야 한다. login_channel(channel_slug: ...) 을 채널 수만큼.")
