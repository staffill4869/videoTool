defmodule VideoTool.AudioTagStripTest do
  use ExUnit.Case, async: true

  alias VideoTool.Projects

  # 자막에 "[excited]" 가 찍혀 나간 적이 있으면 영상을 다시 만들어야 한다.
  test "감정 태그를 떼고 공백을 정리한다" do
    assert Projects.strip_audio_tags("[excited] 어느 날 들른 옆 가게가 바뀌어 있었습니다.") ==
             "어느 날 들른 옆 가게가 바뀌어 있었습니다."

    assert Projects.strip_audio_tags("둘은 [curious] 마주 봤습니다. [sighs]") ==
             "둘은 마주 봤습니다."
  end

  test "대사 속 대괄호가 아닌 것은 건드리지 않는다" do
    assert Projects.strip_audio_tags("정부가 대신 내 줍니다.") == "정부가 대신 내 줍니다."
    assert Projects.strip_audio_tags(nil) == nil
  end
end
