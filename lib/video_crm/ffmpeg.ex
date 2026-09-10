defmodule VideoCRM.Ffmpeg do
  @moduledoc """
  ffmpeg / ffprobe 얇은 감싸기. 외부 바이너리라 없으면 명확히 실패한다.
  """

  @doc "이미지/영상의 크기·길이·fps."
  def probe(path) do
    args = [
      "-v", "error",
      "-select_streams", "v:0",
      "-show_entries", "stream=width,height,r_frame_rate:format=duration",
      "-of", "json",
      path
    ]

    with {:ok, out} <- run("ffprobe", args),
         {:ok, json} <- Jason.decode(out) do
      stream = json |> Map.get("streams", []) |> List.first() || %{}
      duration = json |> Map.get("format", %{}) |> Map.get("duration")

      {:ok,
       %{
         width: stream["width"] || 0,
         height: stream["height"] || 0,
         fps: parse_fps(stream["r_frame_rate"]),
         duration_sec: parse_float(duration)
       }}
    end
  end

  @doc """
  해싱용 축소 흑백 원시 프레임. 기본 9x8 = dHash 한 장.

  `at`: `:first` | `:last`. 이미지는 둘 다 같은 결과다.
  영상 마지막 프레임은 `-sseof` 로 끝에서 되짚는다.
  """
  def gray_frame(path, at \\ :first, w \\ 9, h \\ 8) do
    seek = if at == :last, do: ["-sseof", "-0.2"], else: []

    args =
      seek ++
        [
          "-v", "error",
          "-i", path,
          "-frames:v", "1",
          "-vf", "scale=#{w}:#{h}:flags=area,format=gray",
          "-f", "rawvideo",
          "-"
        ]

    case run_binary("ffmpeg", args) do
      {:ok, bytes} when byte_size(bytes) >= w * h -> {:ok, binary_part(bytes, 0, w * h)}
      {:ok, bytes} -> {:error, "프레임이 짧습니다 (#{byte_size(bytes)}바이트): #{path}"}
      other -> other
    end
  end

  @doc "OCR·섬네일용 실제 프레임을 PNG 로 뽑는다."
  def extract_frame(path, out_path, at \\ :last) do
    seek = if at == :last, do: ["-sseof", "-0.2"], else: []
    args = seek ++ ["-v", "error", "-y", "-i", path, "-frames:v", "1", out_path]

    with {:ok, _} <- run("ffmpeg", args) do
      if File.exists?(out_path), do: {:ok, out_path}, else: {:error, "프레임 추출 실패: #{path}"}
    end
  end

  @doc "필터를 걸어 한 장을 저장한다. OCR 전처리용."
  def filter(path, filter_chain, out_path) do
    args = ["-v", "error", "-y", "-i", path, "-vf", filter_chain, "-frames:v", "1", out_path]

    with {:ok, _} <- run("ffmpeg", args) do
      if File.exists?(out_path), do: {:ok, out_path}, else: {:error, "필터 출력 없음"}
    end
  end

  def available? do
    match?({:ok, _}, run("ffprobe", ["-version"]))
  end

  # ── 실행 ────────────────────────────────────────────────────────

  defp run(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, "#{cmd} 실패 (exit #{code}): #{String.slice(out, 0, 400)}"}
    end
  rescue
    e in ErlangError -> {:error, "#{cmd} 를 실행할 수 없습니다: #{inspect(e.original)}"}
  end

  # rawvideo 는 바이너리라 stderr 를 섞으면 안 된다.
  defp run_binary(cmd, args) do
    port =
      Port.open({:spawn_executable, System.find_executable(cmd) || cmd}, [
        :binary,
        :exit_status,
        :hide,
        args: args
      ])

    collect(port, <<>>)
  rescue
    e -> {:error, "#{cmd} 를 실행할 수 없습니다: #{inspect(e)}"}
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, chunk}} -> collect(port, acc <> chunk)
      {^port, {:exit_status, 0}} -> {:ok, acc}
      {^port, {:exit_status, code}} -> {:error, "ffmpeg 실패 (exit #{code})"}
    after
      30_000 -> {:error, "ffmpeg 응답 없음 (30초)"}
    end
  end

  defp parse_fps(nil), do: nil

  defp parse_fps(rate) do
    case String.split(rate, "/") do
      [num, den] ->
        with {n, _} <- Integer.parse(num),
             {d, _} when d != 0 <- Integer.parse(den) do
          Float.round(n / d, 3)
        else
          _ -> nil
        end

      _ ->
        parse_float(rate)
    end
  end

  defp parse_float(nil), do: nil

  defp parse_float(str) do
    case Float.parse(to_string(str)) do
      {f, _} -> Float.round(f, 3)
      :error -> nil
    end
  end
end