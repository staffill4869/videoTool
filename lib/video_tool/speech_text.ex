defmodule VideoTool.SpeechText do
  @moduledoc """
  **자막 글을 소리 내어 읽는 글로 바꾼다.**

  자막이 원본이다. TTS 는 여기서 파생된다 — 둘을 따로 적으면 반드시 어긋난다
  (실제로 자막엔 "60퍼센트", 대본엔 "육십 퍼센트" 를 손으로 맞춰 적고 있었다).
  화면에는 `60%` 가 뜨고, 일레븐랩스에는 `육십 퍼센트` 가 간다.

  숫자는 한자어로 읽는다 (일·이·삼). 달은 예외가 둘 있다 — 6월은 '유월',
  10월은 '시월' 이다. '육월/십월' 로 읽으면 바로 티가 난다.

  `[excited]` 같은 감정 태그는 건드리지 않는다. 대괄호 안은 그대로 둔다.
  """

  @digits {"영", "일", "이", "삼", "사", "오", "육", "칠", "팔", "구"}
  @months %{"6" => "유", "10" => "시"}

  @units [
    {"%", " 퍼센트"},
    {"㎡", " 제곱미터"},
    {"km", " 킬로미터"},
    {"kg", " 킬로그램"},
    # mg·㎎ 은 g 보다 먼저 봐야 한다. 뒤에서 보면 "500mg" 이 "오백mg" 으로 남는다.
    {"mg", " 밀리그램"},
    {"㎎", " 밀리그램"},
    {"㎍", " 마이크로그램"},
    {"IU", " 아이유"},
    {"cm", " 센티미터"},
    {"mm", " 밀리미터"},
    {"ml", " 밀리리터"},
    {"m", " 미터"},
    {"g", " 그램"},
    {"L", " 리터"}
  ]

  @doc "자막 문장 → TTS 문장."
  def to_speech(nil), do: nil

  def to_speech(text) when is_binary(text) do
    text
    |> months()
    |> numbers()
    |> units()
    |> String.replace(~r/ {2,}/u, " ")
    |> String.trim()
  end

  # 6월·10월만 다르게 읽는다. 나머지는 일반 숫자 규칙으로 간다.
  defp months(text) do
    Regex.replace(~r/(\d{1,2})월/u, text, fn whole, n ->
      case @months[n] do
        nil -> whole
        name -> name <> "월"
      end
    end)
  end

  # 1,234 / 500만 / 12억 같은 덩어리를 한 번에 읽는다.
  # 쉼표를 먼저 떼지 않으면 "2,500만" 이 "이 오백만" 으로 갈라진다.
  defp numbers(text) do
    Regex.replace(~r/(\d[\d,]*)(\.\d+)?\s*(조|억|만|천)?/u, text, fn whole, int, frac, big ->
      case Integer.parse(String.replace(int, ",", "")) do
        {n, ""} -> read(n) <> big <> decimal(frac)
        _ -> whole
      end
    end)
  end

  defp decimal(""), do: ""

  defp decimal("." <> digits) do
    " 점 " <> (digits |> String.graphemes() |> Enum.map_join(" ", &digit/1))
  end

  defp units(text) do
    Enum.reduce(@units, text, fn {from, to}, acc ->
      # 숫자 바로 뒤에 붙은 것만 단위로 본다. 영어 단어 속의 m 을 건드리면 안 된다.
      # `` 를 쓰면 안 된다 — "육십%," 처럼 뒤가 기호면 경계가 안 생겨 그냥 지나간다(테스트가 잡음).
      # 뒤에 영문자가 오면 단위가 아니다 ("km" 를 "k 미터" 로 만들지 않는다).
      Regex.replace(~r/(?<=[가-힣0-9])#{Regex.escape(from)}(?![a-zA-Z])/u, acc, to)
    end)
  end

  defp digit(d), do: elem(@digits, String.to_integer(d))

  @doc false
  def read(0), do: "영"

  def read(n) when n > 0 do
    [{"조", 1_000_000_000_000}, {"억", 100_000_000}, {"만", 10_000}]
    |> Enum.reduce({n, ""}, fn {name, size}, {rest, acc} ->
      q = div(rest, size)
      if q == 0, do: {rest, acc}, else: {rem(rest, size), acc <> chunk(q) <> name}
    end)
    |> then(fn {rest, acc} -> acc <> chunk(rest) end)
  end

  # 0~9999. '일천·일백·일십' 은 쓰지 않는다 — 천·백·십 이라고만 읽는다.
  defp chunk(0), do: ""

  defp chunk(n) do
    [{1000, "천"}, {100, "백"}, {10, "십"}, {1, ""}]
    |> Enum.reduce({n, ""}, fn {size, name}, {rest, acc} ->
      q = div(rest, size)

      cond do
        q == 0 -> {rem(rest, size), acc}
        q == 1 and name != "" -> {rem(rest, size), acc <> name}
        true -> {rem(rest, size), acc <> digit("#{q}") <> name}
      end
    end)
    |> elem(1)
  end
end
