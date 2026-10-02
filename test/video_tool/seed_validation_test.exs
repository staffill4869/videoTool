defmodule VideoTool.SeedValidationTest do
  @moduledoc """
  Flow 를 돌리기 **전에** 시딩 누락을 잡는다.

  20편을 일괄 시딩했더니 같은 날 세 번 터졌다 (2026-10-02):
  segment_text 없음 → 나레이션 실패, series_id 없음 → 도입·마무리가 조용히 안 붙음,
  info_instruction 없음 → 그림 모델에 제약이 없어 영어 글자가 박히고 배경이 빔.
  셋 다 **크레딧을 다 쓴 뒤에야** 드러났다.
  """
  use VideoTool.DataCase, async: false

  alias VideoTool.{Projects, Validation}

  setup do
    Code.eval_file("priv/repo/seeds.exs")

    {:ok, project} =
      Projects.create_project(%{
        "title" => "시딩 검사",
        "target_sec" => 30,
        "style_slug" => "iso-lowpoly",
        "domain_slug" => "history-military",
        "voice_slug" => "mark",
        "output_folder" => System.tmp_dir!()
      })

    {:ok, project} = Projects.get_project(project.id)
    on_exit(fn -> File.rm_rf(project.work_dir) end)
    %{project: project}
  end

  test "빠뜨린 채로 시딩하면 seed 검증이 전부 집어낸다", %{project: project} do
    {:ok, _} = Projects.save_scenes(project, [%{"scene_no" => 1, "target_sec" => 8.0}])
    {:ok, result} = Validation.run(project, "seed")

    refute result.passed
    assert result.checks["has_series"] == false
    assert result.checks["has_shot_prompt"] == false
    assert result.checks["has_info_instruction"] == false
    assert result.checks["has_segment_text"] == false
  end

  test "제대로 채우면 통과한다", %{project: project} do
    {:ok, _script, _} = Projects.save_script(project, "한 줄 대본입니다.", nil, "draft")

    {:ok, _} =
      Projects.save_scenes(project, [
        %{
          "scene_no" => 1,
          "target_sec" => 8.0,
          "shot_prompt" => "작은 가게 디오라마.",
          "info_instruction" => "글자·숫자를 만들지 마라.",
          "segment_text" => "한 줄 대본입니다."
        }
      ])

    {:ok, series} =
      VideoTool.Series.create(%{
        "name" => "검사 시리즈",
        "aspect" => "9:16",
        "style_id" => project.style_id,
        "domain_id" => project.domain_id,
        "voice_id" => project.voice_id
      })
    {:ok, project} = Projects.get_project(project.id)
    {:ok, project} = Projects.update_project(project, %{"series_id" => series.id})

    {:ok, result} = Validation.run(project, "seed")
    assert result.passed, inspect(result.problems)
  end
end
