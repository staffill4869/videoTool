defmodule VideoTool.NarrationCoverTest do
  @moduledoc """
  클립이 모자란 채로 나레이션을 돌리면 **자막이 조용히 사라진다.**

  161 번(기술홈닥터)이 클립 4개뿐일 때 나레이션을 돌았다. 장면 시간이 3칸만 생겼고
  시간을 못 받은 6줄은 자막에서 빠졌다. 음성은 "여러분 미쳤습니다" 로 시작하는데
  자막은 처음부터 여섯째 줄이 떠 있는 영상이 유튜브로 나갔다 (2026-10-03).
  """
  use ExUnit.Case, async: true

  test "시간을 못 받은 대본이 있으면 나레이션이 멈춘다" do
    {:ok, src} = File.read("lib/video_tool/assembly.ex")
    [_, body] = String.split(src, "def save_narration(project, src, opts) do", parts: 2)
    [head, _] = String.split(body, "@doc", parts: 2)

    assert head =~ "untimed"
    assert head =~ "시간이 안 잡혔습니다"

    # 실패를 돌려주기 전에 자막을 쓰면 의미가 없다 — 검사가 replace_subtitles 보다 앞이어야 한다.
    assert :binary.match(head, "untimed") < :binary.match(head, "replace_subtitles")
  end
end
