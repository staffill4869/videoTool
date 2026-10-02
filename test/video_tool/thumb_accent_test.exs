defmodule VideoTool.ThumbAccentTest do
  use ExUnit.Case, async: true

  # 색이 매번 달라지면 다시 만들 때마다 섬네일이 바뀌어 "아까 그거" 를 못 찾는다.
  # 그래서 무작위가 아니라 **프로젝트 번호 기준**이어야 한다.
  test "같은 편은 늘 같은 색, 다른 편은 섞인다" do
    colors = for id <- 1..12, do: VideoTool.Thumbnail.accent_for(id)

    assert VideoTool.Thumbnail.accent_for(7) == Enum.at(colors, 6)
    assert length(Enum.uniq(colors)) > 1, "색이 하나뿐이면 바꾼 의미가 없다"
    assert Enum.all?(colors, &String.match?(&1, ~r/^&H00[0-9A-F]{6}&$/))
  end
end
