defmodule VideoTool.Speech do
  @moduledoc """
  **자막에 쓸 글자와 읽힐 글자를 나눈다.**

  자막은 `10월 2일` 이라고 써야 읽힌다. 그런데 TTS 에 그대로 넣으면 `십월 이일` 로
  잘못 읽는다 — 한국어에서 10월은 `시월`, 6월은 `유월`이라 규칙에서 벗어나 있다.
  그래서 대본을 소리 나는 대로 `시월 이일` 이라 쓰면 이번엔 **자막이 그렇게 나간다**
  (2026-09-30 지적). 둘은 서로 다른 글이므로 여기서 갈라 준다.

  대본에는 **숫자로 쓴다.** 소리로 바꾸는 건 이쪽 일이다.
  """

  @months %{
    1 => "일", 2 => "이", 3 => "삼", 4 => "사", 5 => "오", 6 => "유",
    7 => "칠", 8 => "팔", 9 => "구", 10 => "시", 11 => "십일", 12 => "십이"
  }

  @ones ~w(영 일 이 삼 사 오 육 칠 팔 구)
  @tens ~w(십 이십 삼십)

  @doc """
  읽을 글. 날짜의 달·일만 한글 독음으로 바꾸고 나머지는 건드리지 않는다.

  금액(`2,500만 원`)은 그대로 둔다 — TTS 가 이미 제대로 읽고, 손대면 자릿수가 틀어진다.
  """
  def spoken(nil), do: nil

  def spoken(text) when is_binary(text) do
    text
    |> replace(~r/(\d{1,2})월/u, fn n -> Map.get(@months, n) && Map.get(@months, n) <> "월" end)
    |> replace(~r/(\d{1,2})일(?!자)/u, fn n -> day(n) && day(n) <> "일" end)
  end

  # 1~31 일. 그 밖의 수는 손대지 않는다 (기간·개수일 수 있다).
  defp day(n) when n in 1..9, do: Enum.at(@ones, n)
  defp day(10), do: "십"
  defp day(n) when n in 11..19, do: "십" <> Enum.at(@ones, n - 10)
  defp day(n) when n in [20, 30], do: Enum.at(@tens, div(n, 10) - 1)
  defp day(n) when n in 21..29, do: "이십" <> Enum.at(@ones, n - 20)
  defp day(31), do: "삼십일"
  defp day(_), do: nil

  defp replace(text, re, fun) do
    Regex.replace(re, text, fn whole, digits ->
      case fun.(String.to_integer(digits)) do
        nil -> whole
        said -> said
      end
    end)
  end
end
