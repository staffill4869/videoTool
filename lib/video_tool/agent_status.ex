defmodule VideoTool.AgentStatus do
  @moduledoc """
  무인 루프가 지금 살아 있는지, 무엇을 하고 있는지 한자리에서 본다.

  왜 필요한가: 루프는 조용히 멈춘다. Chrome 이 죽거나, 예약이 꺼졌거나, 에이전트가
  권한에 막혀 아무것도 못 하고 끝나도 화면에는 아무 표시가 없었다 —
  "돌고 있겠거니" 하고 몇 시간이 지나야 알아챘다. 그래서 네 가지를 같이 본다:
  예약 작업 · 지금 실행 중인지 · Chrome · 서버가 마지막으로 한 일.
  """

  require Logger

  alias VideoTool.{Jobs, Media, Projects}

  @lock ".agent.lock"
  @task_name "videoTool-agent"

  @doc "한 번에 다 모은다. 화면이 주기적으로 부른다."
  def snapshot do
    %{
      task: scheduled_task(),
      running: running(),
      chrome: chrome(),
      log: last_log_lines(6),
      projects: projects()
    }
  end

  # ── 예약 작업 ────────────────────────────────────────────────
  # Windows 예약 작업 상태. PowerShell 을 부르므로 자주 부르지 않는다.
  defp scheduled_task do
    script = """
    $t = Get-ScheduledTask -TaskName '#{@task_name}' -ErrorAction SilentlyContinue
    if (-not $t) { 'none||' ; exit }
    $i = Get-ScheduledTaskInfo -TaskName '#{@task_name}'
    "$($t.State)|$($i.LastRunTime)|$($i.NextRunTime)"
    """

    case ps(script) do
      {:ok, out} ->
        case String.split(String.trim(out), "|") do
          ["none", _, _] -> %{registered: false}
          [state, last, next] -> %{registered: true, state: state, last_run: last, next_run: next}
          _ -> %{registered: false}
        end

      _ ->
        %{registered: false, error: "예약 작업을 읽지 못했습니다"}
    end
  end

  # ── 지금 돌고 있나 ───────────────────────────────────────────
  # run-agent.ps1 이 도는 동안만 잠금 파일이 있다. 프로세스를 뒤지는 것보다 싸고 확실하다.
  defp running do
    path = Path.join(File.cwd!(), @lock)

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: m}} ->
        mins = div(System.os_time(:second) - m, 60)
        # 한 시간 넘게 잠겨 있으면 죽은 잠금이다 (run-agent.ps1 도 그렇게 판단한다).
        %{running: mins < 60, since_min: mins, stale: mins >= 60}

      _ ->
        %{running: false}
    end
  end

  # ── Flow 용 Chrome ───────────────────────────────────────────
  defp chrome do
    case Req.get("http://127.0.0.1:9222/json/version", receive_timeout: 2_000, retry: false) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        %{ok: true, browser: body["Browser"]}

      _ ->
        %{ok: false}
    end
  rescue
    _ -> %{ok: false}
  end

  # ── 최근 로그 ────────────────────────────────────────────────
  defp last_log_lines(n) do
    path =
      Path.join([File.cwd!(), "logs", "agent-#{Date.utc_today() |> Date.to_iso8601()}.log"])

    case File.read(path) do
      {:ok, body} ->
        body |> String.split("\n", trim: true) |> Enum.take(-n)

      _ ->
        []
    end
  end

  # ── 프로젝트별 진행 ──────────────────────────────────────────
  @doc """
  프로젝트마다 어느 단계까지 왔는지, 지금 무엇을 기다리는지.

  `now` 는 사람이 읽을 한 줄이다 — 숫자를 보고 매번 머리로 계산하지 않게.
  """
  def projects do
    Projects.list_projects()
    |> Enum.map(fn p ->
      counts = Media.asset_counts(p.id)
      scenes = length(Projects.scenes(p.id))
      renders = length(Media.renders(p.id))
      published = p.id |> VideoTool.Publishing.publications() |> Enum.any?(&(&1.status == "published"))
      job = Jobs.latest_flow_job(p.id)

      %{
        id: p.id,
        title: p.title,
        series_id: p.series_id,
        scenes: scenes,
        clean: counts["clean"] || 0,
        info: counts["info"] || 0,
        clip: counts["clip"] || 0,
        renders: renders,
        published: published,
        job: job && %{stage: job.model, status: job.status, at: job.requested_at},
        now: describe(scenes, counts, renders, published, job)
      }
    end)
  end

  defp describe(scenes, counts, renders, published, job) do
    clean = counts["clean"] || 0
    info = counts["info"] || 0
    clip = counts["clip"] || 0

    cond do
      job && job.status == "running" -> "#{stage_ko(job.model)} 생성 중"
      published -> "발행됨"
      renders > 0 -> "발행 대기"
      scenes == 0 -> "대본 대기"
      clean < scenes -> "CLEAN 대기 (#{clean}/#{scenes})"
      info < scenes -> "INFO 대기 (#{info}/#{scenes})"
      clip < scenes -> "VIDEO 대기 (#{clip}/#{scenes})"
      true -> "합성 대기"
    end
  end

  defp stage_ko("clean"), do: "CLEAN"
  defp stage_ko("info"), do: "INFO"
  defp stage_ko("video"), do: "VIDEO"
  defp stage_ko(other), do: other

  defp ps(script) do
    case System.cmd("powershell", ["-NoProfile", "-NonInteractive", "-Command", script],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, "exit #{code}: #{String.slice(out, 0, 120)}"}
    end
  rescue
    _ -> {:error, "powershell 실행 실패"}
  end
end
