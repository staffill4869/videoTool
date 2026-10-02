defmodule VideoTool.ThumbFitTest do
  use ExUnit.Case, async: true

  alias VideoTool.Thumbnail

  @l1 "비타민C 한 번에 먹으면"
  @l2 "대부분 빠져나간다"

  # 사용자 지시(2026-10-01): 세로판 제목 띠는 높이의 2.5/16 (1920 → 300) 을 넘지 않는다.
  test "세로판 띠는 2.5/16 을 넘지 않고, 긴 줄일수록 글자가 작아진다" do
    {fs, band} = Thumbnail.layout(1080, 1920, [@l1, @l2])
    assert band <= 300
    {fs_long, band_long} = Thumbnail.layout(1080, 1920, ["비타민C를 한 번에 몰아서 드시나요", @l2])
    assert fs_long < fs and band_long <= 300
  end

  # 숫자 어림이 아니라 실제로 그려서 본다: 글자가 띠 안에만 있고, 좌우로 잘리지 않고, 줄이 안 갈린다.
  # (7자에서 끊었더니 "비타민C 한 / 번에 먹으면" 으로 말이 갈렸다)
  test "그려 보면 글자가 띠 안에, 한 줄씩 들어간다" do
    for l1 <- [@l1, "비타민C를 한 번에 몰아서 드시나요"] do
      {rows, cols, w, band} = render(l1, @l2)
      top = Thumbnail.band_top()
      assert hd(rows) >= top, "글자가 띠 위로 나갔다: #{l1}"
      assert List.last(rows) < top + band, "글자가 띠 아래로 나갔다: #{l1}"
      assert hd(cols) > 10 and List.last(cols) < w - 10, "글자가 좌우로 잘렸다: #{l1}"

      # 두 덩어리(두 줄)만 — 줄이 갈리면 세 덩어리 이상
      blocks = rows |> Enum.chunk_while([], fn y, acc -> if acc == [] or y - hd(acc) <= 3, do: {:cont, [y | acc]}, else: {:cont, acc, [y]} end, &{:cont, &1, []})
      assert length(blocks) == 2, "줄이 갈렸다: #{l1}"
    end
  end

  # 둘째 줄 색은 편마다 바뀐다. 루마로 보면 초록(&H0066FF66&) 이 192 라 글자가 통째로 사라져
  # "줄이 갈렸다" 로 잘못 잡혔다 — 그래서 밝기가 아니라 **RGB 최댓값**으로 글자를 찾는다.
  # 밝은 글자 픽셀(흰 줄 · 노란 줄)이 있는 행 · 열 — 회색 그림(128)과 검은 띠는 빠진다
  defp render(l1, l2) do
    dir = Path.join(System.tmp_dir!(), "thumbfit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    src = Path.join(dir, "src.png")
    {_, 0} = System.cmd("ffmpeg", ~w(-v error -y -f lavfi -i color=c=gray:s=768x1376 -frames:v 1) ++ [src])
    {:ok, out} = Thumbnail.compose_vertical(%{id: 1, output_folder: dir}, l1, l2, src)
    {_, band} = Thumbnail.layout(1080, 1920, [l1, l2])

    pgm = Path.join(dir, "bright.pgm")
    {_, 0} = System.cmd("ffmpeg", ["-v", "error", "-y", "-i", out, "-vf", "format=rgb24,geq=r='if(gt(max(max(r(X,Y),g(X,Y)),b(X,Y)),200),255,0)':g='if(gt(max(max(r(X,Y),g(X,Y)),b(X,Y)),200),255,0)':b='if(gt(max(max(r(X,Y),g(X,Y)),b(X,Y)),200),255,0)',format=gray", "-c:v", "pgm", "-f", "image2", pgm])
    {w, h, px} = read_pgm(pgm)
    rows = for y <- 0..(h - 1), Enum.any?(0..(w - 1)//2, &(:binary.at(px, y * w + &1) > 0)), do: y
    top = Thumbnail.band_top()
    cols = for x <- 0..(w - 1), Enum.any?(top..(top + band - 1)//2, &(:binary.at(px, &1 * w + x) > 0)), do: x
    {rows, cols, w, band}
  end

  defp read_pgm(path) do
    bin = File.read!(path)
    [_magic, dims, _max, _] = String.split(binary_part(bin, 0, 40), "\n", parts: 4)
    [w, h] = dims |> String.split() |> Enum.map(&String.to_integer/1)
    {w, h, binary_part(bin, byte_size(bin) - w * h, w * h)}
  end
end
