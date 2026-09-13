defmodule VideoTool.Clipboard do
  @moduledoc """
  Windows 클립보드에 텍스트를 넣는다.

  프롬프트가 7천 자를 넘어서 명령줄 인자로 넘기면 길이 제한에 걸린다.
  그래서 UTF-8 파일로 떨군 뒤 PowerShell 이 그 파일을 읽어 클립보드에 넣게 한다.
  (`clip.exe` 는 콘솔 코드페이지를 타서 한글이 깨진다 — 쓰지 말 것.)
  """

  require Logger

  @doc "성공하면 {:ok, 글자수}."
  def put(text) when is_binary(text) do
    path = Path.join(System.tmp_dir!(), "video_tool_clip_#{System.unique_integer([:positive])}.txt")

    try do
      File.write!(path, text)
      run_powershell(path, String.length(text))
    after
      File.rm(path)
    end
  end

  defp run_powershell(path, char_count) do
    script =
      "Set-Clipboard -Value ([System.IO.File]::ReadAllText('#{path}', " <>
        "[System.Text.Encoding]::UTF8))"

    case System.cmd("powershell", ["-NoProfile", "-NonInteractive", "-Command", script],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        {:ok, char_count}

      {out, code} ->
        Logger.error("클립보드 주입 실패 (exit #{code}): #{out}")
        {:error, "클립보드에 넣지 못했습니다: #{String.trim(out)}"}
    end
  rescue
    e in ErlangError ->
      # powershell 을 못 찾는 경우 (비 Windows 환경 등)
      {:error, "클립보드를 쓸 수 없는 환경입니다: #{inspect(e)}"}
  end

  @doc "확인용. 방금 넣은 것이 맞는지 되읽는다."
  def get do
    case System.cmd("powershell", ["-NoProfile", "-NonInteractive", "-Command", "Get-Clipboard"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e in ErlangError -> {:error, inspect(e)}
  end
end

defmodule VideoTool.Clipboard.Noop do
  @moduledoc "테스트용. 실제 클립보드를 건드리지 않는다 — 테스트가 사용자 클립보드를 덮어쓰면 안 된다."
  def put(text), do: {:ok, String.length(text)}
  def get, do: {:ok, ""}
end
