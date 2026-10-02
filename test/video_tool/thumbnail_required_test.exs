defmodule VideoTool.ThumbnailRequiredTest do
  use ExUnit.Case, async: true

  # 섬네일 없이 발행되는 걸 막는다. 무인 루프 지시문에 단계를 적어 뒀지만
  # 지시는 건너뛸 수 있다 — 2026-09-30 까지 올라간 23편 중 18편에 섬네일이
  # 없었거나 엉뚱한 그림(898x786 연락지 격자)이 올라가 있었다.
  #
  # 판정은 이름이 아니라 **비율**로 한다. compose 는 1280x720 으로만 만든다.
  @dir Path.join(System.tmp_dir!(), "vt_thumb_required_test")

  setup do
    File.rm_rf!(@dir)
    File.mkdir_p!(@dir)
    on_exit(fn -> File.rm_rf!(@dir) end)
    :ok
  end

  defp make(name, w, h) do
    path = Path.join(@dir, name)

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=gray:s=#{w}x#{h}",
         "-frames:v", "1", path],
        stderr_to_stdout: true
      )

    path
  end

  defp ratio_ok?(path) do
    case VideoTool.Ffmpeg.probe(path) do
      {:ok, %{width: w, height: h}} when w > 0 and h > 0 -> abs(w / h - 16 / 9) < 0.1
      _ -> false
    end
  end

  test "1280x720 은 섬네일로 받는다" do
    assert ratio_ok?(make("ok.jpg", 1280, 720))
  end

  test "연락지 격자(898x786)는 거른다" do
    refute ratio_ok?(make("sheet.jpg", 898, 786))
  end

  test "세로본(1080x1920)은 거른다 — 유튜브가 좌우에 띠를 붙여 16:9 로 만든다" do
    refute ratio_ok?(make("vertical.jpg", 1080, 1920))
  end

  test "없는 파일은 거른다" do
    refute ratio_ok?(Path.join(@dir, "없음.jpg"))
  end
end
