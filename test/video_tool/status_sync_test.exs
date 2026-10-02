defmodule VideoTool.StatusSyncTest do
  use VideoTool.DataCase, async: true

  alias VideoTool.Projects

  # 화면의 진행 눈금 여덟 칸은 오직 project.status 만 본다. 그런데 그 값을 올리는
  # 코드가 scripted·scened 둘뿐이라, 발행까지 끝난 편도 눈금이 장면에서 멈춰 있었다
  # (2026-09-30 확인: 16편 전부). 판정을 데이터에서 끌어온다.
  test "상태는 뒤로 가지 않는다" do
    for {from, to} <- [{"done", "draft"}, {"assembled", "scened"}, {"narrated", "scripted"}] do
      assert Projects.Project.status_index(from) > Projects.Project.status_index(to),
             "#{from} 이 #{to} 보다 앞이어야 한다"
    end
  end

  test "여덟 칸이 상태 아홉 가지와 맞는다" do
    # Progress 의 눈금표와 Projects 의 상태 목록이 어긋나면 눈금이 통째로 밀린다.
    assert length(Projects.Project.statuses()) == length(VideoTool.Progress.steps()) + 1

    for s <- Projects.Project.statuses(), do: assert(is_integer(VideoTool.Progress.ticks(s)))
    assert VideoTool.Progress.ticks("done") == 8
    assert VideoTool.Progress.ticks("scened") == 2
  end
end
