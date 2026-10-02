defmodule VideoTool.SpeechWindowTest do
  use ExUnit.Case, async: true

  # 자막이 말보다 늦게 뜨던 버그 (2026-10-02, 152번).
  # 장면 구간은 클립 길이에서 나와 음성 위치를 모른다 — 5장면 자막이 0.52초 늦게 떴다.
  # 말 토막 수가 장면 수와 맞으면 음성에서 직접 뽑은 구간을 쓴다.
  @silences [
    %{"start" => 4.005, "end" => 4.347},
    %{"start" => 8.234, "end" => 8.621},
    %{"start" => 11.613, "end" => 11.927},
    %{"start" => 15.122, "end" => 15.397},
    %{"start" => 18.055, "end" => 18.456},
    %{"start" => 22.116, "end" => 24.449},
    # 쉼표 뒤의 짧은 쉼 — 0.25초 미만이라 장면 경계로 세면 안 된다
    %{"start" => 26.209, "end" => 26.392}
  ]

  defp segments do
    [
      "가게를 넓히려고 은행에 갔는데 담보부터 내놓으라고 했습니다.",
      "모아 둔 담보가 없어서 그 자리에서 공사를 접었습니다.",
      "그런데 바로 옆 가게는 그 달에 공사를 시작했습니다.",
      "알고 보니 안산시가 보증을 대신 서 주고 있었습니다.",
      "한 업체당 최대 오천만 원까지 보증해 줍니다.",
      "안산시 안에서 장사하는 소상공인이면 신청할 수 있습니다.",
      "담보가 없어서 미뤄 둔 공사, 혹시 있으신가요?"
    ]
    |> Enum.with_index(1)
    |> Enum.map(fn {text, i} -> %{scene_id: i, text: text} end)
  end

  test "자막이 말하는 구간 안에 들어간다" do
    segments = segments()
    timing = for s <- segments, do: %{"scene_id" => s.scene_id, "start" => 0.0, "end" => 27.455}

    rows = VideoTool.Assembly.subtitle_rows_for_test(segments, timing, @silences, 27.455)

    assert length(rows) == 14

    # 5장면 첫 줄은 말이 시작하는 15.397 에 맞아야 한다 (예전엔 15.915 로 0.52초 늦었다)
    fifth = Enum.at(rows, 8)
    assert_in_delta fifth.start_sec, 15.397, 0.05

    # 마지막 자막이 음성 길이를 넘지 않는다 (예전엔 1초 넘겼다)
    assert List.last(rows).end_sec <= 27.46
  end
end
