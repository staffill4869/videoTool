defmodule VideoTool.MappingTest do
  @moduledoc """
  이미 채워진 장면은 배정 후보에서 빠져야 한다.

  71·72 편에서 3·5·7 번 장면만 새로 뽑았는데 결과가 1·2·3 번에 붙었다. 배정이 파일 순서를
  **1번 장면부터** 깔기 때문인데, 사람이 대조표를 눈으로 보고 매번 SQL 로 되돌렸다.
  장면을 하나씩 이어 붙이는 사슬 구조에서는 이게 여덟 번 반복되므로 여기서 막는다.
  """
  use VideoTool.DataCase, async: false

  alias VideoTool.{Mapping, Media, Projects}

  setup do
    Code.eval_file("priv/repo/seeds.exs")

    {:ok, project} =
      Projects.create_project(%{
        "title" => "배정 후보 테스트",
        "target_sec" => 32,
        "style_slug" => "iso-lowpoly",
        "domain_slug" => "history-military",
        "voice_slug" => "mark"
      })

    {:ok, project} = Projects.get_project(project.id)

    {:ok, _} =
      Projects.save_scenes(
        project,
        Enum.map(1..4, fn n ->
          %{
            "scene_no" => n,
            "target_sec" => 8.0,
            "shot_prompt" => "SHOT S0#{n}",
            "info_instruction" => "다음 순간 #{n}",
            "expected_labels" => []
          }
        end)
      )

    {:ok, project: project, scenes: Projects.scenes(project.id)}
  end

  defp asset!(project, scene_id, kind, name), do: asset!(project, scene_id, kind, name, "approved")

  defp asset!(project, scene_id, kind, name, status) do
    {:ok, a} =
      Media.create_asset(%{
        project_id: project.id,
        scene_id: scene_id,
        kind: kind,
        source: "flow",
        file_path: Path.join(System.tmp_dir!(), name),
        source_filename: name,
        phash: "",
        status: status
      })

    a
  end

  test "앞 장면이 이미 차 있으면 새 CLEAN 은 다음 빈 장면부터 붙는다", ctx do
    [s1, s2, s3, _s4] = ctx.scenes
    asset!(ctx.project, s1.id, "clean", "old_1.png")
    asset!(ctx.project, s2.id, "clean", "old_2.png")

    fresh = asset!(ctx.project, nil, "clean", "new_a.png")
    {:ok, project} = Projects.get_project(ctx.project.id)

    assignment = Mapping.assign(project, "clean", [fresh])
    {scene_id, _confidence} = Map.fetch!(assignment, fresh.id)

    assert scene_id == s3.id,
           "3번이 아니라 #{inspect(scene_id)} 에 붙었다 — 채워진 장면을 후보에서 빼지 못했다"
  end

  test "반려된 자산은 장면을 막지 않는다", ctx do
    [s1 | _] = ctx.scenes
    asset!(ctx.project, s1.id, "clean", "rejected_1.png", "rejected")

    fresh = asset!(ctx.project, nil, "clean", "new_b.png")
    {:ok, project} = Projects.get_project(ctx.project.id)

    [{_id, {scene_id, _}}] = Map.to_list(Mapping.assign(project, "clean", [fresh]))
    assert scene_id == s1.id, "반려분이 1번 장면을 계속 점유하고 있다"
  end

  test "전부 차 있으면 '전부 다시' 로 읽어 1번부터 배정한다", ctx do
    [s1 | _] = ctx.scenes
    Enum.each(ctx.scenes, &asset!(ctx.project, &1.id, "clean", "full_#{&1.scene_no}.png"))

    fresh = asset!(ctx.project, nil, "clean", "redo.png")
    {:ok, project} = Projects.get_project(ctx.project.id)

    [{_id, {scene_id, _}}] = Map.to_list(Mapping.assign(project, "clean", [fresh]))
    assert scene_id == s1.id
  end

  test "이번에 요청한 장면 안에서만 배정한다", ctx do
    [_s1, _s2, s3, _s4] = ctx.scenes

    fresh = asset!(ctx.project, nil, "clean", "wanted_3.png")
    {:ok, project} = Projects.get_project(ctx.project.id)

    [{_id, {scene_id, _}}] = Map.to_list(Mapping.assign(project, "clean", [fresh], [3]))

    assert scene_id == s3.id,
           "3번만 요청했는데 다른 장면에 붙었다 — 회수 배정이 요청 장면을 모른다"
  end

  test "INFO 도 요청한 장면을 따른다 — 유사도가 애매해도", ctx do
    [s1, s2 | _] = ctx.scenes
    asset!(ctx.project, s1.id, "clean", "clean_1.png")

    fresh = asset!(ctx.project, nil, "info", "info_for_1.png")
    {:ok, project} = Projects.get_project(ctx.project.id)

    [{_id, {scene_id, _}}] = Map.to_list(Mapping.assign(project, "info", [fresh], [1]))

    refute scene_id == s2.id, "1번을 요청했는데 2번에 붙었다 (73번에서 실제로 난 일)"
    assert scene_id == s1.id
  end
end
