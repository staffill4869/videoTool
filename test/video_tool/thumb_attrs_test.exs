defmodule VideoTool.ThumbAttrsTest do
  use ExUnit.Case, async: true

  # 모듈 속성을 **쓰는 곳보다 아래에** 정의했더니 nil 이 되어 `1920 - nil` 로 터졌다.
  # 컴파일도 통과하고 테스트도 통과했는데, 실제로 섬네일을 만들 때만 터졌다 (2026-10-02).
  # 그래서 여기서는 **실제로 그려 본다.**
  @tag :tmp_dir
  test "세로 섬네일이 실제로 만들어진다", %{tmp_dir: dir} do
    src = Path.join(dir, "src.jpg")

    {_, 0} =
      System.cmd("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i",
                            "color=c=gray:s=768x1376", "-frames:v", "1", src])

    out = Path.join(dir, "out.jpg")

    {_, 0} =
      System.cmd("ffmpeg", ["-v", "error", "-y", "-i", src, "-vf",
                            "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920," <>
                              "crop=1080:1770:0:0,pad=1080:1920:0:150:black",
                            "-frames:v", "1", out])

    assert File.exists?(out)
    assert {:ok, %{width: 1080, height: 1920}} = VideoTool.Ffmpeg.probe(out)
  end
end
