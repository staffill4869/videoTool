defmodule VideoTool.SpeechRateTest do
  use ExUnit.Case, async: true

  alias VideoTool.Assembly

  # 0 이면 손대지 않는다. 대부분의 목소리가 그렇다.
  test "0 이면 속도를 바꾸지 않는다" do
    assert Assembly.speech_rate(%{voice: %{speech_rate: 0.0}}) == 0.0
    assert Assembly.speech_rate(%{voice: nil}) == 0.0
  end

  # 너무 올리면 급하게 읽는 티가 난다. 너무 내리면 늘어진다.
  test "0.8 ~ 1.5 로 가둔다" do
    assert Assembly.speech_rate(%{voice: %{speech_rate: 1.12}}) == 1.12
    assert Assembly.speech_rate(%{voice: %{speech_rate: 3.0}}) == 1.5
    assert Assembly.speech_rate(%{voice: %{speech_rate: 0.3}}) == 0.8
  end
end
