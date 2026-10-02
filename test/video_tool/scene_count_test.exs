defmodule VideoTool.SceneCountTest do
  use ExUnit.Case, async: true

  alias VideoTool.Work

  # 예전에는 "장면 8개" 가 지시문에 박혀 있어서 어떤 편이든 64초가 나왔다.
  # 쇼츠는 1분을 넘으면 안 된다 — 여기서 막는다.
  test "장면 수는 목표 길이에서 나오고, 영상은 1분을 넘지 않는다" do
    for target <- 20..120 do
      n = Work.scene_count_for(target)
      assert n >= 3, "#{target}초: 장면이 너무 적다 (#{n})"
      assert n * 8 < 60, "#{target}초: 영상이 #{n * 8}초로 1분을 넘는다"
    end

    # 실제 시리즈 값
    assert Work.scene_count_for(60) == 7
    assert Work.scene_count_for(44) == 6
    assert Work.scene_count_for(32) == 4
  end
end
