defmodule VideoTool.PromptLanguageTest do
  @moduledoc """
  화면 글자 언어는 **프로젝트 언어**가 정한다.

  2026-09-29: 한국어 편인데 INFO 이미지에 "kitten days", "hunting education" 같은
  영어 라벨이 박혀 나왔다. 그림체 프리셋 12개가 전부 `표기언어: "한국어"` 를 들고
  있는데, 그게 프로젝트 언어보다 **뒤에** 병합돼서 영어판을 만들어도 화면만 한국어가
  되는 구멍도 함께 있었다. 소리와 글자가 어긋나면 보는 사람이 두 번 읽는다.
  """
  use VideoTool.DataCase, async: false

  alias VideoTool.Prompt

  test "그림체가 표기언어를 들고 있어도 프로젝트 언어가 이긴다" do
    p = project("en", style_vars: %{"표기언어" => "한국어"})

    assert Prompt.variables(p)["표기언어"] == VideoTool.Projects.language_label("en")
  end

  test "한국어 편은 한국어로 나온다" do
    p = project("ko", style_vars: %{"표기언어" => "English"})

    assert Prompt.variables(p)["표기언어"] == VideoTool.Projects.language_label("ko")
  end

  test "프로젝트에 손으로 넣은 값은 여전히 이긴다 — 한 편만 예외 두는 길은 남긴다" do
    p = project("ko", style_vars: %{"표기언어" => "English"}, project_vars: %{"표기언어" => "일본어"})

    assert Prompt.variables(p)["표기언어"] == "일본어"
  end

  test "그림체는 표기언어 말고 다른 변수는 그대로 이긴다" do
    p =
      project("ko",
        domain_vars: %{"그래픽효과" => "장르 것"},
        style_vars: %{"그래픽효과" => "그림체 것"}
      )

    assert Prompt.variables(p)["그래픽효과"] == "그림체 것"
  end

  defp uniq, do: System.unique_integer([:positive])

  defp project(lang, opts) do
    style =
      Repo.insert!(%VideoTool.Presets.StylePreset{
        slug: "s#{uniq()}",
        name: "그림체",
        variables: Keyword.get(opts, :style_vars, %{})
      })

    domain =
      Repo.insert!(%VideoTool.Presets.DomainPreset{
        slug: "d#{uniq()}",
        name: "장르",
        variables: Keyword.get(opts, :domain_vars, %{})
      })

    voice =
      Repo.insert!(%VideoTool.Presets.Voice{
        slug: "v#{uniq()}",
        display_name: "목소리",
        provider: "elevenlabs",
        voice_id: "x"
      })

    Repo.insert!(%VideoTool.Projects.Project{
      title: "언어 시험 #{uniq()}",
      language: lang,
      style_id: style.id,
      domain_id: domain.id,
      voice_id: voice.id,
      variables: Keyword.get(opts, :project_vars, %{})
    })
    |> Repo.preload([:style, :domain])
  end
end
