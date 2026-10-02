defmodule VideoTool.SpeechTest do
  use ExUnit.Case, async: true

  alias VideoTool.Speech

  # 자막은 "10월 2일", 음성은 "시월 이일". 대본에 소리대로 쓰면 자막이 그렇게 나간다.
  test "달과 일을 한글 독음으로 바꾼다" do
    assert Speech.spoken("접수는 10월 2일까지입니다.") == "접수는 시월 이일까지입니다."
    assert Speech.spoken("6월 15일") == "유월 십오일"
    assert Speech.spoken("1월 31일") == "일월 삼십일일"
    assert Speech.spoken("12월 20일") == "십이월 이십일"
  end

  # 10월과 6월이 규칙에서 벗어난다. TTS 가 틀리는 건 사실상 이 둘뿐이다.
  test "시월과 유월" do
    assert Speech.spoken("10월") == "시월"
    assert Speech.spoken("6월") == "유월"
    refute Speech.spoken("10월") =~ "십월"
  end

  # 금액은 건드리지 않는다. 손대면 자릿수가 틀어진다.
  test "금액과 다른 숫자는 그대로 둔다" do
    assert Speech.spoken("최대 2,500만 원까지") == "최대 2,500만 원까지"
    assert Speech.spoken("80퍼센트") == "80퍼센트"
    assert Speech.spoken("2개 社") == "2개 社"
  end

  test "날짜가 없으면 원문 그대로" do
    t = "자부담은 절반 이상입니다."
    assert Speech.spoken(t) == t
    assert Speech.spoken(nil) == nil
  end
end
