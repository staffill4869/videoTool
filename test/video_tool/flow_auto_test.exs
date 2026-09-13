defmodule VideoTool.FlowAutoTest do
  @moduledoc """
  Flow 브라우저 자동 조종의 분기.

  가장 중요한 건 **깨졌을 때 멈추지 않는가** 다. Flow 는 Labs 제품이라 UI 가 바뀌게 돼 있고,
  바뀐 날 작업이 통째로 서면 자동화가 오히려 손해다. 그래서 실패 경로를 먼저 고정한다.
  """
  use VideoTool.DataCase, async: false

  alias VideoTool.{Jobs, Pipeline, Projects}

  setup do
    Code.eval_file("priv/repo/seeds.exs")

    {:ok, project} =
      Projects.create_project(%{
        "title" => "자동 조종 테스트",
        "target_sec" => 30,
        "style_slug" => "iso-lowpoly",
        "domain_slug" => "history-military",
        "voice_slug" => "mark",
        "output_folder" => System.tmp_dir!()
      })

    {:ok, project} = Projects.get_project(project.id)
    {:ok, _script, _} = Projects.save_script(project, "본문", nil, "draft")

    {:ok, _} =
      Projects.save_scenes(project, [
        %{"scene_no" => 1, "target_sec" => 8.0, "shot_prompt" => "SHOT S01", "expected_labels" => ["가"]},
        %{"scene_no" => 2, "target_sec" => 8.0, "shot_prompt" => "SHOT S02", "expected_labels" => ["나"]}
      ])

    script = Projects.active_script(project.id)
    {:ok, _} = Projects.save_allowed_facts(script, [%{"kind" => "place", "value" => "남한산성"}])

    prev = Application.get_env(:video_tool, :flow_stub_status)
    on_exit(fn ->
      Application.put_env(:video_tool, :flow_stub_status, prev)
      File.rm_rf(project.work_dir)
    end)

    {:ok, project: project}
  end

  defp as_auto(project) do
    {:ok, updated} = Projects.set_pipeline(project, "flow_auto")
    {:ok, reloaded} = Projects.get_project(updated.id)
    reloaded
  end

  test "기본값은 수동이다 — 켜지 않으면 브라우저를 건드리지 않는다", %{project: project} do
    assert project.pipeline == "ai"

    result = Pipeline.next(project)

    assert result.action == "clipboard"
    refute Map.has_key?(result, :flow_auto_unavailable)
    refute_received {:flow_started, _, _}
  end

  test "자동이 켜져 있고 준비됐으면 생성을 걸고 기다리라고 답한다", %{project: project} do
    Application.put_env(:video_tool, :flow_stub_status, {:ok, %{flow_tab: true, prompt_box: true}})
    project = as_auto(project)

    result = Pipeline.next(project)

    assert result.action == "wait"
    assert result.mode == "flow_auto"
    assert result.poll_after_sec > 0
    assert_received {:flow_started, _id, "clean"}
  end

  test "Chrome 이 없으면 멈추지 않고 수동으로 되돌아간다", %{project: project} do
    Application.put_env(:video_tool, :flow_stub_status, {:error, "Chrome 에 붙지 못했습니다"})
    project = as_auto(project)

    result = Pipeline.next(project)

    # 자동이 안 되더라도 프롬프트는 클립보드에 들어가 있어야 한다
    assert result.action == "clipboard"
    assert result.clipboard_written
    assert result.flow_auto_unavailable =~ "Chrome"
    assert result.message =~ "수동으로 진행하세요"
    refute_received {:flow_started, _, _}
  end

  test "로그인이 안 돼 있으면(입력칸이 안 보이면) 역시 수동으로 되돌아간다", %{project: project} do
    Application.put_env(
      :video_tool,
      :flow_stub_status,
      {:ok, %{flow_tab: true, prompt_box: false, hint: "Flow 에 로그인이 필요합니다"}}
    )

    project = as_auto(project)
    result = Pipeline.next(project)

    assert result.action == "clipboard"
    assert result.flow_auto_unavailable =~ "로그인"
    refute_received {:flow_started, _, _}
  end

  test "생성이 도는 중에는 끼어들지 않는다", %{project: project} do
    Application.put_env(:video_tool, :flow_stub_status, {:ok, %{flow_tab: true, prompt_box: true}})
    project = as_auto(project)

    {:ok, _} =
      Jobs.record_generation(%{
        project_id: project.id,
        provider: "flow",
        model: "clean",
        status: "running",
        requested_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    result = Pipeline.next(project)

    assert result.action == "wait"
    assert result.message =~ "생성 중"
    # 이미 돌고 있는데 또 걸면 같은 프롬프트를 두 번 생성해 크레딧을 두 배로 쓴다
    refute_received {:flow_started, _, _}
  end

  test "pipeline 값은 아는 것만 받는다", %{project: project} do
    assert {:error, changeset} = Projects.set_pipeline(project, "아무거나")
    assert %{pipeline: _} = errors_on(changeset)
  end
end