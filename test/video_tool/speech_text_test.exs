defmodule VideoTool.SpeechTextTest do
  use ExUnit.Case, async: true

  alias VideoTool.SpeechText

  test "숫자를 한자어로 읽는다" do
    assert SpeechText.read(60) == "육십"
    assert SpeechText.read(500) == "오백"
    assert SpeechText.read(16) == "십육"
    assert SpeechText.read(2026) == "이천이십육"
    assert SpeechText.read(1) == "일"
    assert SpeechText.read(10) == "십"
    assert SpeechText.read(100) == "백"
    assert SpeechText.read(120_000_000) == "일억이천만"
  end

  test "실제 대본 문장" do
    assert SpeechText.to_speech("공사비의 60%, 한 곳당 500만 원까지 나옵니다.") ==
             "공사비의 육십 퍼센트, 한 곳당 오백만 원까지 나옵니다."

    assert SpeechText.to_speech("영업신고한 지 2년 지난 음식점이면 신청할 수 있습니다.") ==
             "영업신고한 지 이년 지난 음식점이면 신청할 수 있습니다."
  end

  # 6월·10월을 '육월·십월' 로 읽으면 바로 티가 난다.
  test "달 이름 예외" do
    assert SpeechText.to_speech("접수는 10월 16일까지입니다.") == "접수는 시월 십육일까지입니다."
    assert SpeechText.to_speech("6월 3일") == "유월 삼일"
    assert SpeechText.to_speech("9월 1일") == "구월 일일"
  end

  test "감정 태그는 건드리지 않는다" do
    assert SpeechText.to_speech("[excited] 60%가 나옵니다") == "[excited] 육십 퍼센트가 나옵니다"
  end

  test "단위와 소수" do
    assert SpeechText.to_speech("1m 앞") == "일 미터 앞"
    assert SpeechText.to_speech("90㎡ 이하") == "구십 제곱미터 이하"
    assert SpeechText.to_speech("1.5kg") == "일 점 오 킬로그램"
    assert SpeechText.to_speech("2,500만 원") == "이천오백만 원"
    # mg 를 g 보다 먼저 보지 않으면 "오백mg" 이 남는다
    assert SpeechText.to_speech("한 번에 500mg") == "한 번에 오백 밀리그램"
    assert SpeechText.to_speech("1000IU") == "천 아이유"
  end
end
