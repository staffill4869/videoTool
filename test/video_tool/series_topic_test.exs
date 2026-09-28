defmodule VideoTool.SeriesTopicTest do
  @moduledoc """
  같은 주제로 두 번 만들지 않는다.

  2026-09-23: 시리즈 5 에서 네 편이 **시리즈 기본 주제 그대로** 만들어졌다.
  `run_series` 에 topic 을 안 주면 `topic_brief` 로 떨어지는데, 그건 시리즈 설명이지
  이번 편 주제가 아니다. 결과적으로 거의 같은 영상이 유튜브에 네 번 올라갔다.
  """
  use VideoTool.DataCase, async: false

  alias VideoTool.Series

  test "기본 주제로 두 번째 편을 만들면 거부한다" do
    s = series()

    {:ok, _} = Series.spawn_project(s)
    {:ok, s} = Series.get(s.id)

    assert {:error, msg} = Series.spawn_project(s)
    assert msg =~ "이미 만들었습니다"
  end

  test "이번 편 주제를 주면 만든다" do
    s = series()

    {:ok, _} = Series.spawn_project(s, topic: "고양이는 왜 꾹꾹이를 할까")
    {:ok, s} = Series.get(s.id)
    {:ok, p} = Series.spawn_project(s, topic: "고양이는 왜 밤에 뛰어다닐까")

    assert p.topic == "고양이는 왜 밤에 뛰어다닐까"
  end

  test "준 주제가 이미 쓴 것이면 거부한다" do
    s = series()

    {:ok, _} = Series.spawn_project(s, topic: "꾹꾹이")
    {:ok, s} = Series.get(s.id)

    # 앞뒤 공백만 다른 것도 같은 주제다
    assert {:error, _} = Series.spawn_project(s, topic: "  꾹꾹이 ")
  end

  test "used_topics 는 끝난 편도 내준다 — 그래야 피할 수 있다" do
    s = series()
    {:ok, _} = Series.spawn_project(s, topic: "가")
    {:ok, s} = Series.get(s.id)
    {:ok, _} = Series.spawn_project(s, topic: "나")

    assert [{_, "나"}, {_, "가"}] = Series.used_topics(s.id)
  end

  defp uniq, do: System.unique_integer([:positive])

  defp series do
    style = Repo.insert!(%VideoTool.Presets.StylePreset{slug: "s#{uniq()}", name: "그림체"})
    domain = Repo.insert!(%VideoTool.Presets.DomainPreset{slug: "d#{uniq()}", name: "장르"})

    voice =
      Repo.insert!(%VideoTool.Presets.Voice{
        slug: "v#{uniq()}",
        display_name: "목소리",
        provider: "elevenlabs",
        voice_id: "x"
      })

    {:ok, s} =
      Series.create(%{
        "name" => "고양이는 왜 그럴까 #{uniq()}",
        "topic_brief" => "고양이의 행동과 몸을 '왜 그런가' 로 푸는 시리즈",
        "style_id" => style.id,
        "domain_id" => domain.id,
        "voice_id" => voice.id,
        "interval_minutes" => 60,
        "max_pending" => 5,
        "active" => true,
        "output_folder" => System.tmp_dir!()
      })

    {:ok, s} = Series.get(s.id)
    s
  end
end
