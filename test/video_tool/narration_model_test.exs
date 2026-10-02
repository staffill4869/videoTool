defmodule VideoTool.NarrationModelTest do
  use ExUnit.Case, async: true

  # 태그를 읽는 모델로 되돌아가면 나레이션 첫 문장이 "큐리어스 …" 로 나간다.
  test "기본 TTS 모델은 감정 태그를 읽지 않는 모델이다" do
    {:ok, src} = File.read("lib/video_tool/narration.ex")
    assert src =~ ~s(@model "eleven_v3")
    refute src =~ "multilingual_v2\""
  end
end
