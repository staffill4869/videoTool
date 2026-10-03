defmodule VideoTool.SpeechRateFieldTest do
  @moduledoc """
  `voices.speech_rate` 는 **배속**이다. 한 가지 뜻으로만 쓴다.

  예전에는 저장할 때 -0.2~0.1 "증감폭" 으로 막고, 쓸 때는 0.8~1.5 배속으로 읽었다.
  그래서 0.1 을 넣으면 assembly 가 max(0.1, 0.8) 로 올려 **오히려 0.8 배로 느려졌고**,
  실제로 쓰고 있던 유니(1.12)는 검증을 통과할 수 없는 값이었다 (2026-10-04).
  """
  use ExUnit.Case, async: true

  alias VideoTool.Presets.Voice

  defp rate(v), do: Voice.changeset(%Voice{voice_id: "x", display_name: "d", slug: "s"}, %{speech_rate: v})

  test "0 과 0.8~1.5 만 받는다" do
    for ok <- [0.0, 0.8, 1.12, 1.3, 1.5] do
      assert rate(ok).valid?, "#{ok} 는 통과해야 한다"
    end

    for bad <- [0.1, 0.5, 0.79, 1.51, -0.2] do
      refute rate(bad).valid?, "#{bad} 는 막아야 한다"
    end
  end

  test "쓰는 쪽도 같은 뜻으로 읽는다" do
    project = %{voice: %{speech_rate: 1.3}}
    assert VideoTool.Assembly.speech_rate(project) == 1.3

    assert VideoTool.Assembly.speech_rate(%{voice: %{speech_rate: 0.0}}) == 0.0
  end
end
