defmodule VideoTool.SubtitleChunkTest do
  use ExUnit.Case, async: true

  alias VideoTool.Assembly

  # 예전에는 문장 부호에서만 끊어서, 한 줄이 4초씩 떠 있었다.
  # 짧게 끊어야 눈이 따라간다 — 한 토막이 18자를 넘으면 안 된다.
  test "긴 문장을 18자 이하 토막으로 끊는다" do
    long = "외국인 근로자 기숙사를 고치면 포항시가 2,500만 원을 냅니다"
    parts = Assembly.chunk(long)

    assert length(parts) > 1
    for p <- parts, do: assert(String.length(p) <= 18, "너무 길다: #{p} (#{String.length(p)}자)")

    # 글자를 잃거나 더하지 않는다.
    assert String.replace(Enum.join(parts, " "), " ", "") == String.replace(long, " ", "")
  end

  test "짧은 문장은 그대로 둔다" do
    assert Assembly.chunk("절반은 내 돈입니다.") == ["절반은 내 돈입니다."]
  end

  test "쉼표가 있으면 거기서 끊는다" do
    [first | _] = Assembly.chunk("대상은 포항시 중소기업이고, 기숙사를 가지고 있어야 합니다")
    assert String.ends_with?(first, ",")
  end

  # 쉼표도 띄어쓰기도 없는 긴 덩어리는 자를 자리가 없다. 무한 재귀로 빠지면 안 된다.
  test "끊을 자리가 없어도 멈춘다" do
    assert Assembly.chunk(String.duplicate("가", 40)) == [String.duplicate("가", 40)]
  end

  # 뒤 토막이 한 마디만 남으면 0.75초만 떠서 안 읽힌다. 반씩 나눠야 한다.
  test "토막을 고르게 나눈다 — 뒤가 한 마디만 남지 않는다" do
    parts = Assembly.chunk("절반을 내고도 고칠 값어치가 있을까요?")
    assert length(parts) == 2
    [a, b] = parts
    assert String.length(b) >= 6, "뒤 토막이 너무 짧다: #{b}"
    assert abs(String.length(a) - String.length(b)) <= 6
  end

  # 98편에서 "2,500만 원" 이 천 단위 쉼표에서 잘려 "500만 원" 으로 떴다.
  # 금액이 다섯 배 틀린 자막이 나갈 뻔했다.
  test "천 단위 쉼표에서는 자르지 않는다" do
    parts = Assembly.chunk("외국인 근로자 기숙사를 고치면 포항시가 2,500만 원까지 지원합니다.")

    assert Enum.any?(parts, &String.contains?(&1, "2,500")),
           "2,500 이 쪼개졌다: #{inspect(parts)}"

    refute Enum.any?(parts, &String.starts_with?(&1, "500")),
           "천 단위 쉼표에서 잘렸다: #{inspect(parts)}"
  end
end
