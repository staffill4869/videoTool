defmodule VideoCRM.Phash do
  @moduledoc """
  dHash. 9x8 흑백으로 줄인 뒤 가로로 이웃 픽셀을 비교해 64비트를 만든다.

  엘릭서용 perceptual hash 라이브러리가 없어서 직접 계산한다 — ffmpeg 가 이미 축소·흑백을
  해주므로 남는 일은 비교 64번뿐이다.

  average hash 가 아니라 dHash 인 이유: INFO 이미지는 CLEAN 위에 라벨·화살표를 얹은 것이라
  평균 밝기가 눈에 띄게 달라진다. 이웃 간 기울기는 그보다 훨씬 덜 흔들린다.
  """

  alias VideoCRM.Ffmpeg

  @width 9
  @height 8

  @doc "파일에서 바로. `at` 은 :first | :last."
  def of_file(path, at \\ :first) do
    with {:ok, bytes} <- Ffmpeg.gray_frame(path, at, @width, @height) do
      {:ok, of_gray(bytes)}
    end
  end

  @doc "9x8 흑백 원시 바이트 → 16자리 16진 문자열."
  def of_gray(bytes) when byte_size(bytes) == @width * @height do
    bits =
      for row <- 0..(@height - 1),
          col <- 0..(@width - 2) do
        left = :binary.at(bytes, row * @width + col)
        right = :binary.at(bytes, row * @width + col + 1)
        if left > right, do: 1, else: 0
      end

    bits
    |> Enum.reduce(0, fn bit, acc -> acc * 2 + bit end)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(16, "0")
  end

  @doc "다른 비트 개수 (0~64). 낮을수록 닮았다."
  def distance(a, b) when is_binary(a) and is_binary(b) do
    with {x, ""} <- Integer.parse(a, 16), {y, ""} <- Integer.parse(b, 16) do
      popcount(Bitwise.bxor(x, y), 0)
    else
      _ -> 64
    end
  end

  @doc "0.0 ~ 1.0."
  def similarity(a, b), do: 1.0 - distance(a, b) / 64.0

  defp popcount(0, acc), do: acc
  defp popcount(n, acc), do: popcount(Bitwise.bsr(n, 1), acc + Bitwise.band(n, 1))
end