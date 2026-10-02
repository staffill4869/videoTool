defmodule VideoTool.ThumbBreakTest do
  use ExUnit.Case, async: true

  # 소스에 역슬래시를 한 번만 쓰면 Elixir 가 먹어 화면에 글자가 그대로 찍힌다.
  # 실제로 "비타민C 한N번에 먹으면"(\N), "{c&H0055E7FF&}"(\c) 가 섬네일에 나갔다.
  # 만들어진 ASS 파일을 직접 본다.
  test "ASS 지시문(\\N · \\c · \\pos)이 역슬래시와 함께 나간다" do
    dir = Path.join(System.tmp_dir!(), "thumbbreak-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    src = Path.join(dir, "src.png")
    {_, 0} = System.cmd("ffmpeg", ~w(-v error -y -f lavfi -i color=c=gray:s=768x1376 -frames:v 1) ++ [src])
    {:ok, _} = VideoTool.Thumbnail.compose_vertical(%{id: 1, output_folder: dir}, "비타민C 한 번에", "대부분 빠져나간다", src)

    dialogue = dir |> Path.join("1/thumb916.ass") |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "Dialogue:"))

    for tag <- ["N", "c&H", "pos("] do
      assert String.contains?(dialogue, <<92>> <> tag), "#{tag} 앞 역슬래시가 없습니다: #{dialogue}"
    end

    refute dialogue =~ ~r/[^\\]N대부분/u, "역슬래시가 먹혀 글자 N 이 남았습니다: #{dialogue}"
  end
end
