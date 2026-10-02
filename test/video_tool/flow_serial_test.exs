defmodule VideoTool.FlowSerialTest do
  use ExUnit.Case, async: true

  # Flow 는 브라우저 창 하나다. 152·153 이 15초 차이로 들어가 서로 깨뜨린 적이 있다
  # (2026-10-02). 검사가 **그 프로젝트 것만** 보고 있었던 탓이다.
  test "Flow 작업 자리잡기는 전역이고, 보는 것과 넣는 것이 한 트랜잭션이다" do
    {:ok, flow} = File.read("lib/video_tool/flow.ex")
    [_, body] = String.split(flow, "def run_stage_async(")

    assert body =~ "pg_advisory_xact_lock", "DB 자물쇠가 없다"
    assert body =~ "Jobs.running_flow_jobs()", "전역 검사가 아니다"
    assert body =~ "Repo.transaction", "검사와 등록이 한 트랜잭션이 아니다"

    # 등록은 트랜잭션 안에서만 일어나야 한다
    [before_tx, _] = String.split(body, "Repo.transaction", parts: 2)
    refute before_tx =~ "record_generation", "트랜잭션 밖에서 작업을 등록한다"
  end

  test "flow_generate 는 다른 편이 돌고 있어도 막는다" do
    {:ok, mcp} = File.read("lib/video_tool/mcp.ex")
    [_, after_handler] = String.split(mcp, ~S|defp handle("flow_generate", args) do|, parts: 2)
    [guard, _] = String.split(after_handler, "Flow.run_stage_async", parts: 2)

    assert guard =~ "Jobs.running_flow_jobs()"
    refute guard =~ "running_flow_job(project.id)", "프로젝트 한정 검사가 남아 있다"
  end
end
