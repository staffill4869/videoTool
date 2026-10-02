defmodule VideoTool.PolitenessTest do
  use ExUnit.Case, async: true

  # 편마다 말투가 달라지면 같은 채널로 안 보인다.
  # 영양제 #43 은 존댓말, #44·#45 는 평서체로 나갔다 (2026-09-30 실측).
  # 지시문은 에이전트에게만 전달되는 글이라 단위 시험으로 잡을 데가 여기뿐이다.
  test "대본 지시문이 존댓말을 못 박는다" do
    src = File.read!("lib/video_tool/work.ex")

    assert src =~ "말투는 존댓말로 통일합니다"
    assert src =~ "평서체를 섞지 마세요"
  end
end
