defmodule VideoTool.Credentials do
  @moduledoc """
  OAuth 토큰 저장소. 윈도우는 DPAPI, 리눅스는 AES-GCM 으로 암호화해 파일에 둔다.

  DB 에 넣지 않는 이유는 설명서 7장 그대로다 — DB 파일이 유출돼도 계정이 털리면 안 된다.

  ## 윈도우 (DPAPI)
  DPAPI 는 **현재 윈도우 사용자 계정에 묶여** 암호화하므로, 암호문 파일을 통째로 복사해
  다른 PC 나 다른 계정에서 열어도 복호화되지 않는다.

  평문을 명령줄 인자로 넘기지 않는다 — 작업 관리자·이벤트 로그에 그대로 남는다.
  임시 파일로 건네고 즉시 지운다.

  ## 리눅스 (AES-256-GCM)
  **DPAPI 는 윈도우 API 라 리눅스에 없다.** powershell 을 부르던 코드가 그대로 돌면
  `powershell 을 실행할 수 없습니다` 로 전부 실패한다 — 서버에서 유튜브 발행이
  통째로 막힌다(실측 2026-09-23: 채널이 전부 `connected: false`).

  그래서 리눅스에서는 키 파일 하나로 AES-GCM 암복호화한다.
  키는 `$VIDEOCRM_CRED_KEY`(base64 32바이트) 또는 `<root>/.key`(600) 에서 읽고,
  없으면 **처음 쓸 때 만들어 둔다.**

  DPAPI 만큼 강하지 않다 — 키 파일과 암호문이 같은 디스크에 있으니, 디스크를 통째로
  가져가면 열린다. 그 대신 **DB·백업·git 에는 안 들어간다**(`.credentials/` 는 gitignore).
  더 세게 묶고 싶으면 키를 KMS 같은 데로 옮긴다.
  """


  @doc "저장. `ref` 는 Channel.credential_ref (예: videoTool/youtube/yt-main)."
  def put(ref, secret) when is_binary(secret) do
    if windows?(), do: put_dpapi(ref, secret), else: put_aes(ref, secret)
  end

  defp put_dpapi(ref, secret) do
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
    if windows?(), do: get_dpapi(ref), else: get_aes(ref)
  end

  defp get_dpapi(ref) do
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

  defp windows?, do: match?({:win32, _}, :os.type())

  # ── 리눅스: AES-256-GCM ────────────────────────────────────────
  # 파일 모양: <12바이트 IV><16바이트 태그><암호문>
  @aad "videocrm-credential"

  defp put_aes(ref, secret) do
    target = path_for(ref)
    File.mkdir_p!(Path.dirname(target))
    iv = :crypto.strong_rand_bytes(12)

    {ct, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, aes_key(), iv, secret, @aad, true)

    with :ok <- File.write(target, iv <> tag <> ct),
         # 남이 읽으면 안 된다. 기본 권한으로 두면 같은 서버의 다른 사용자가 읽는다.
         :ok <- File.chmod(target, 0o600) do
      {:ok, ref}
    else
      {:error, r} -> {:error, "자격증명을 저장하지 못했습니다: #{inspect(r)}"}
    end
  end

  defp get_aes(ref) do
    target = path_for(ref)

    case File.read(target) do
      {:ok, <<iv::binary-12, tag::binary-16, ct::binary>>} ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, aes_key(), iv, ct, @aad, tag, false) do
          :error ->
            # 키가 바뀌었거나 파일이 손상됐다. 둘을 구분할 방법이 없으므로 그대로 알린다.
            {:error, "자격증명을 읽지 못했습니다: 키가 맞지 않습니다 (다시 연결하세요)"}

          plain ->
            {:ok, plain}
        end

      {:ok, _short} ->
        {:error, "자격증명 파일이 손상됐습니다: #{target}"}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, r} ->
        {:error, "자격증명을 읽지 못했습니다: #{inspect(r)}"}
    end
  end

  # 키는 환경변수 우선, 없으면 <root>/.key. 둘 다 없으면 만들어 둔다.
  # **이 파일을 잃으면 저장된 토큰을 못 연다** — 채널을 다시 연결해야 한다.
  defp aes_key do
    case System.get_env("VIDEOCRM_CRED_KEY") do
      nil -> key_from_file()
      b64 -> decode_key!(b64, "VIDEOCRM_CRED_KEY")
    end
  end

  defp key_from_file do
    path = Path.join(root(), ".key")

    case File.read(path) do
      {:ok, b64} ->
        decode_key!(String.trim(b64), path)

      {:error, :enoent} ->
        key = :crypto.strong_rand_bytes(32)
        File.mkdir_p!(root())
        File.write!(path, Base.encode64(key))
        File.chmod!(path, 0o600)
        key

      {:error, r} ->
        raise "자격증명 키를 읽지 못했습니다 (#{path}): #{inspect(r)}"
    end
  end

  defp decode_key!(b64, where) do
    case Base.decode64(b64) do
      {:ok, <<key::binary-32>>} -> key
      _ -> raise "#{where} 는 base64 로 인코딩된 32바이트여야 합니다"
    end
  end

  # PowerShell 7 이 깔려 있으면 PSModulePath 앞쪽에 그 경로가 끼어든다. 그러면
  # Windows PowerShell 5.1 이 호환되지 않는 Microsoft.PowerShell.Security 를 집어서
  # "모듈을 찾았지만 로드할 수 없습니다" 로 죽는다 — 실측: 유튜브 토큰 저장이 여기서 실패했다.
  # 그래서 이 자식 프로세스에서만 5.1 기본 경로로 되돌린다.
  @ps51_modules "C:\Program Files\WindowsPowerShell\Modules;" <>
                  "C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules"

  defp powershell(script) do
    case System.cmd("powershell", ["-NoProfile", "-NonInteractive", "-Command", script],
           stderr_to_stdout: true,
           env: [{"PSModulePath", @ps51_modules}]
         ) do
      {_out, 0} -> {:ok, :done}
      {out, code} -> {:error, "exit #{code}: #{String.slice(out, 0, 300)}"}
    end
  rescue
    e in ErlangError -> {:error, "powershell 을 실행할 수 없습니다: #{inspect(e.original)}"}
  end
end