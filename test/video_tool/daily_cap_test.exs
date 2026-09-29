defmodule VideoTool.DailyCapTest do
  @moduledoc """
  하루 발행 상한.

  2026-09-23 에 무인 루프가 한 채널에 8편을 올렸다. 두 가지가 겹쳤다:
    1. 같은 주제로 여러 프로젝트를 만들었다 — `already_published?` 는 **같은 렌더**만 막는다
    2. 업로드는 성공했는데 뒤 단계가 실패해 `failed` 로 남은 행을
       "아직 안 올렸다" 로 보고 재시도했다

  그래서 상한은 **status 가 아니라 external_id 로** 센다.

  재발행 자체를 어떻게 풀었는지는 아래 "다시 저장해도" 시험을 본다.
  """
  use VideoTool.DataCase, async: false

  alias VideoTool.Publishing
  alias VideoTool.Publishing.{Channel, Publication}

  setup do
    old = Application.get_env(:video_tool, :daily_publish_cap)
    on_exit(fn -> Application.put_env(:video_tool, :daily_publish_cap, old) end)
    Application.put_env(:video_tool, :daily_publish_cap, 3)
    :ok
  end

  test "올라간 것은 status 와 무관하게 센다 — failed 여도 external_id 가 있으면 한 편" do
    ch = channel()

    pub(ch, "published", "aaa")
    # 업로드는 됐는데 뒤 단계가 실패한 행 ← 이번 사고의 핵심
    pub(ch, "failed", "bbb")
    # 아직 안 올린 초안은 세지 않는다
    pub(ch, "draft", "")

    assert Publishing.uploaded_today(ch) == 2
    assert Publishing.under_daily_cap?(ch)
  end

  test "상한에 닿으면 막는다" do
    ch = channel()
    for i <- 1..3, do: pub(ch, "published", "v#{i}")

    assert Publishing.uploaded_today(ch) == 3
    refute Publishing.under_daily_cap?(ch)
  end

  test "어제 올린 것은 오늘 상한에 안 들어간다" do
    ch = channel()
    pub(ch, "published", "old", days_ago: 1)
    pub(ch, "published", "new")

    assert Publishing.uploaded_today(ch) == 1
  end

  test "다른 채널 것은 안 센다" do
    a = channel()
    b = channel()
    pub(a, "published", "x")
    pub(a, "published", "y")
    pub(b, "published", "z")

    assert Publishing.uploaded_today(a) == 2
    assert Publishing.uploaded_today(b) == 1
  end

  test "상한 0 은 무제한 — 막는 게 기본이지만 끄는 길은 있어야 한다" do
    Application.put_env(:video_tool, :daily_publish_cap, 0)
    ch = channel()
    for i <- 1..5, do: pub(ch, "published", "v#{i}")

    assert Publishing.daily_cap() == 0
    assert Publishing.under_daily_cap?(ch)
  end


  test "발행된 행에 제목을 다시 저장해도 status 가 draft 로 돌아가지 않는다" do
    ch = channel()
    p = pub(ch, "published", "vid123")
    project = Repo.get!(VideoTool.Projects.Project, p.project_id)
    render = Repo.get!(VideoTool.Media.Render, p.render_id)

    {:ok, saved, _warnings} =
      Publishing.save_publish_meta(project, ch, render, %{
        "title" => "제목만 고침",
        "description" => "본문"
      })

    assert saved.title == "제목만 고침"
    # ← 여기가 2026-09-23 중복 업로드의 원인이었다
    assert saved.status == "published"
    assert saved.external_id == "vid123"
  end

  test "초안에 제목을 저장하면 그대로 draft 다" do
    ch = channel()
    p = pub(ch, "draft", "")
    project = Repo.get!(VideoTool.Projects.Project, p.project_id)
    render = Repo.get!(VideoTool.Media.Render, p.render_id)

    {:ok, saved, _} = Publishing.save_publish_meta(project, ch, render, %{"title" => "ㄱ"})
    assert saved.status == "draft"
  end


  test "제목만 다시 저장한 옛 발행물은 오늘 것으로 세지 않는다" do
    ch = channel()
    old = pub(ch, "published", "old", days_ago: 5)
    # 오늘 메타만 건드린다 — updated_at 은 오늘이 되지만 published_at 은 그대로다
    Repo.update!(Ecto.Changeset.change(old, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)))

    pub(ch, "published", "new")

    assert Publishing.uploaded_today(ch) == 1
  end

  # ── fixtures ────────────────────────────────────────────────────
  # publications 는 project·channel·render 가 전부 NOT NULL FK 라 최소 그래프가 필요하다.

  defp uniq, do: System.unique_integer([:positive])

  defp channel do
    Repo.insert!(%Channel{
      platform: "youtube",
      slug: "cap-#{uniq()}",
      display_name: "상한 시험"
    })
  end

  defp project do
    style =
      Repo.insert!(%VideoTool.Presets.StylePreset{slug: "s#{uniq()}", name: "시험 그림체"})

    domain =
      Repo.insert!(%VideoTool.Presets.DomainPreset{slug: "d#{uniq()}", name: "시험 장르"})

    voice =
      Repo.insert!(%VideoTool.Presets.Voice{
        slug: "v#{uniq()}",
        display_name: "시험 목소리",
        provider: "elevenlabs",
        voice_id: "x"
      })

    Repo.insert!(%VideoTool.Projects.Project{
      title: "상한 시험 #{uniq()}",
      style_id: style.id,
      domain_id: domain.id,
      voice_id: voice.id
    })
  end

  defp pub(channel, status, external_id, opts \\ []) do
    p = project()
    r =
      Repo.insert!(%VideoTool.Media.Render{
        project_id: p.id,
        kind: "final",
        aspect: "9:16",
        file_path: "/tmp/cap-test-#{uniq()}.mp4"
      })

    at =
      DateTime.utc_now()
      |> DateTime.add(-86_400 * Keyword.get(opts, :days_ago, 0), :second)
      |> DateTime.truncate(:second)

    Repo.insert!(%Publication{
      project_id: p.id,
      channel_id: channel.id,
      render_id: r.id,
      status: status,
      external_id: external_id,
      # 올린 시각. 안 올린 초안은 nil 이다 — 상한은 이 값을 본다.
      published_at: if(external_id == "", do: nil, else: at),
      inserted_at: at,
      updated_at: at
    })
  end
end
