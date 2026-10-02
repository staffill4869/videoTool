defmodule VideoTool.FillFilterTest do
  use ExUnit.Case, async: true

  alias VideoTool.Assembly

  # Flow 가 가끔 세로 주문을 가로(1280x720)로 내놓는다. 그걸 세로 판에 끼울 때
  # 검은 띠가 생기면 사용자가 바로 알아본다 — 153(안산시) "이건 뭥;ㅁ", 157 1번 장면.
  # 숫자 어림이 아니라 실제로 그려서 위아래 띠 자리가 까맣지 않은지 본다.
  test "가로 클립을 세로 판에 넣어도 위아래가 까맣지 않다" do
    dir = System.tmp_dir!() |> Path.join("fill_filter_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    out = Path.join(dir, "out.png")

    {_, 0} =
      System.cmd("ffmpeg", [
        "-v", "error", "-y",
        # 가로 원본: 전체가 선명한 초록이라, 결과에 까만 자리가 있으면 그건 띠다.
        "-f", "lavfi", "-i", "color=c=green:s=1280x720:d=1",
        "-vf", Assembly.fill_filter(1080, 1920),
        "-frames:v", "1", out
      ])

    # 위 / 가운데 / 아래 세 자리를 찍어 본다.
    for y <- [40, 960, 1880] do
      {rgb, 0} =
        System.cmd("ffmpeg", [
          "-v", "error", "-i", out,
          "-vf", "crop=1:1:540:#{y}",
          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"
        ])

      <<r, g, b>> = rgb
      assert max(r, max(g, b)) > 40, "y=#{y} 가 까맣다 (#{r},#{g},#{b}) — 검은 띠가 남아 있다"
    end
  end
end
