defmodule VideoTool.Ocr do
  @moduledoc """
  tesseract 감싸기. 설치돼 있지 않으면 **없는 척하지 않는다** —
  허용 수치 검증은 OCR 이 있어야만 성립하므로, 못 돌린 검사를 통과로 기록하면 안 된다.

  같은 이유로 **"아무것도 못 읽음" 과 "읽었는데 문제 없음" 을 구분한다.**
  라벨이 있어야 할 이미지에서 빈 결과가 나온 것은 통과가 아니라 검증 실패다.

  설치: `scoop install tesseract` + tessdata 에 `kor.traineddata`.
  """

  alias VideoTool.Ffmpeg

  # 화면에 흩어진 라벨은 문단이 아니다. psm 11(희소 텍스트)이 기본 psm 3 보다 훨씬 잘 읽는다.
  @psm "11"

  @doc "tesseract 가 kor 을 지원하는 상태로 설치돼 있는가."
  def available? do
    case System.cmd("tesseract", ["--list-langs"], stderr_to_stdout: true) do
      {out, 0} -> String.contains?(out, "kor")
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  이미지에서 텍스트를 읽는다.

  `{:ok, text}` — 읽었다(빈 문자열일 수 있다. 그건 호출자가 판단한다)
  `{:error, reason}` — 실행 자체가 실패했다
  """
  def text(path, lang \\ "kor+eng") do
    base = Path.join(System.tmp_dir!(), "vcrm_ocr_#{System.unique_integer([:positive])}")
    prepared = base <> "_in.png"

    try do
      source = if match?({:ok, _}, preprocess(path, prepared)), do: prepared, else: path

      case System.cmd("tesseract", [source, base, "-l", lang, "--psm", @psm],
             stderr_to_stdout: true
           ) do
        {_, 0} -> File.read(base <> ".txt")
        {out, code} -> {:error, "tesseract 실패 (exit #{code}): #{String.slice(out, 0, 300)}"}
      end
    rescue
      _ -> {:error, "tesseract 가 설치돼 있지 않습니다"}
    after
      File.rm(base <> ".txt")
      File.rm(prepared)
    end
  end

  @doc "읽을 만한 글자가 나왔는가. 공백뿐이면 못 읽은 것이다."
  def legible?(text), do: String.trim(to_string(text)) != ""

  # tesseract 는 작고 색이 들어간 글자에 약하다. 키우고 흑백으로 눕히면 확 좋아진다.
  defp preprocess(path, out_path) do
    Ffmpeg.filter(path, "scale=iw*3:ih*3:flags=lanczos,format=gray,eq=contrast=1.6", out_path)
  end

  @doc """
  화면에 뜬 텍스트에서 허용 목록 밖의 수치를 찾는다.

  숫자를 포함한 토큰만 본다 — 화면의 모든 단어를 화이트리스트에 넣을 수는 없고,
  실제로 사고가 난 것도 "예상 30일", "33% 시간 감소" 같은 지어낸 수치였다.
  """
  def out_of_whitelist(text, allowed_values) do
    allowed = Enum.map(allowed_values, &normalize/1)

    text
    |> String.split(~r/[\s,]+/u, trim: true)
    |> Enum.filter(&String.match?(&1, ~r/\d/))
    |> Enum.map(&String.trim(&1, "."))
    |> Enum.uniq()
    |> Enum.reject(fn token ->
      n = normalize(token)
      n == "" or Enum.any?(allowed, &(String.contains?(&1, n) or String.contains?(n, &1)))
    end)
  end

  # 공백·괄호 따위를 걷어내고 비교한다. OCR 은 띄어쓰기를 자주 틀린다.
  defp normalize(s) do
    s
    |> String.replace(~r/[\s()\[\]{}·,]/u, "")
    |> String.downcase()
  end
end