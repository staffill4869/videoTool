defmodule VideoTool.Credentials do
  @moduledoc """
  OAuth 토큰 저장소. Windows DPAPI 로 암호화해 파일에 둔다.

  DB 에 넣지 않는 이유는 설명서 7장 그대로다 — DB 파일이 유출돼도 계정이 털리면 안 된다.
  DPAPI 는 **현재 윈도우 사용자 계정에 묶여** 암호화하므로, 암호문 파일을 통째로 복사해
  다른 PC 나 다른 계정에서 열어도 복호화되지 않는다.

  평문을 명령줄 인자로 넘기지 않는다 — 작업 관리자·이벤트 로그에 그대로 남는다.
  임시 파일로 건네고 즉시 지운다.
  """


  @doc "저장. `ref` 는 Channel.credential_ref (예: videoTool/youtube/yt-main)."
  def put(ref, secret) when is_binary(secret) do
    plain = tmp_path("plain")
    target = path_for(ref)
    File.mkdir_p!(Path.dirname(target))

    try do
      File.write!(plain, secret)

      script = """
      $p = [System.IO.File]::ReadAllText('#{escape(plain)}', [System.Text.Encoding]::UTF8)
      $s = ConvertTo-SecureString -String $p -AsPlainText -Force
      ConvertFrom-SecureString -SecureString $s | Set-Content -Path '#{escape(target)}' -Encoding ascii -NoNewline
      """

      case powershell(script) do
        {:ok, _} -> {:ok, ref}
        {:error, reason} -> {:error, "자격증명을 저장하지 못했습니다: #{reason}"}
      end
    after
      File.rm(plain)
    end
  end

  @doc "읽기. 없으면 {:error, :not_found}."
  def get(ref) do
    target = path_for(ref)

    if File.exists?(target) do
      out = tmp_path("out")

      try do
        script = """
        $e = [System.IO.File]::ReadAllText('#{escape(target)}', [System.Text.Encoding]::ASCII)
        $s = ConvertTo-SecureString -String $e
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
        try {
          $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
          [System.IO.File]::WriteAllText('#{escape(out)}', $plain, (New-Object System.Text.UTF8Encoding($false)))
        } finally {
          [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
        }
        """

        case powershell(script) do
          {:ok, _} -> File.read(out)
          {:error, reason} -> {:error, "자격증명을 읽지 못했습니다: #{reason}"}
        end
      after
        File.rm(out)
      end
    else
      {:error, :not_found}
    end
  end

  @doc "연결 해제. 토큰만 지운다 — Channel 행은 남긴다."
  def delete(ref) do
    ref |> path_for() |> File.rm()
    :ok
  end

  def exists?(ref), do: ref |> path_for() |> File.exists?()

  @doc "저장 위치. .gitignore 에 들어 있어야 한다."
  def root do
    Application.get_env(:video_tool, :credentials_dir) ||
      Path.join(File.cwd!(), ".credentials")
  end

  # ref 를 파일명으로 눕힌다. 경로 구분자가 섞여 있어도 상위 폴더로 못 나가게 한다.
  defp path_for(ref) do
    safe = String.replace(ref, ~r/[^A-Za-z0-9._-]/, "_")
    Path.join(root(), safe <> ".dat")
  end

  defp tmp_path(kind) do
    Path.join(System.tmp_dir!(), "vcrm_cred_#{kind}_#{System.unique_integer([:positive])}.txt")
  end

  defp escape(path), do: String.replace(path, "'", "''")

  defp powershell(script) do
    case System.cmd("powershell", ["-NoProfile", "-NonInteractive", "-Command", script],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> {:ok, :done}
      {out, code} -> {:error, "exit #{code}: #{String.slice(out, 0, 300)}"}
    end
  rescue
    e in ErlangError -> {:error, "powershell 을 실행할 수 없습니다: #{inspect(e.original)}"}
  end
end