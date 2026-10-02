defmodule VideoTool.FinalAspectTest do
  use ExUnit.Case, async: true

  # 가로 클립 하나가 최종 검증을 통과해 유튜브에 올라갔다 (2026-10-02).
  # 화면비 검사가 "clips" 단계에만 있었고, 발행 전에 부르는 것은 "final" 뿐이었다.
  test "final 검사가 클립 화면비를 본다" do
    {:ok, src} = File.read("lib/video_tool/validation.ex")
    [_, final] = String.split(src, ~S|defp check(project, "final") do|)
    assert final =~ "aspect_problems(project"
    assert final =~ ~S|"clip_aspect"|
  end
end
