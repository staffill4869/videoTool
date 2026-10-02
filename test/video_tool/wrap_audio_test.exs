defmodule VideoTool.WrapAudioTest do
  use ExUnit.Case, async: true

  # 본편이 44100 모노로 구워지는 바람에 48000 스테레오인 마무리와 규격이 어긋나
  # `-c copy` 이어붙이기 뒤쪽이 라디오 음성처럼 들렸다 (2026-10-02, 안산시 편).
  test "본편 오디오는 48000 스테레오로 굽는다" do
    {:ok, src} = File.read("lib/video_tool/assembly.ex")

    aac_lines =
      src
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, ~s("aac")))

    assert aac_lines != []

    for line <- aac_lines do
      assert String.contains?(line, ~s("48000")), "48000 이 빠졌다: #{String.trim(line)}"
      assert String.contains?(line, ~s("-ac")), "채널 수가 빠졌다: #{String.trim(line)}"
    end
  end
end
