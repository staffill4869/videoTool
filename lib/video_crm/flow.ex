defmodule VideoCRM.Flow do
  @moduledoc """
  Flow 브라우저 조종. `priv/flow_driver/driver.mjs` 를 한 동작마다 한 번씩 부른다.

  Flow 에는 API 가 없어서 UI 를 직접 조종하는 것 외에 방법이 없다. 대신 세 가지를 지킨다.

    1. **로그인은 사람이 한다.** 이미 로그인된 Chrome 에 CDP 로 붙을 뿐 자격증명을 만지지 않는다
    2. **요청량을 늘리지 않는다.** 사람이 하던 것을 같은 속도로 대신한다
    3. **깨지면 수동으로 되돌아간다.** 버튼을 못 찾으면 프롬프트를 클립보드에 넣고 사람에게 넘긴다

  UI 가 바뀌었을 때 고칠 곳은 이 파일이 아니라 `priv/flow_driver/selectors.json` 이다.
  """

  require Logger

  alias VideoCRM.Jobs

  @default_timeout 30_000

  @doc "Chrome 에 붙을 수 있는지, Flow 탭이 열려 있는지."
  def status, do: run(%{action: "status"}, @default_timeout)

  @doc "프롬프트를 넣고 생성 버튼을 누른다."
  def paste_and_generate(prompt) do
    run(%{action: "paste_and_generate", prompt: prompt}, 60_000)
  end

  @doc """
  결과가 `expect` 개 나올 때까지 기다린다.
  Veo 는 분 단위로 걸리므로 기본 15분을 준다.
  """
  def wait_results(expect, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 900_000)
    since = Keyword.get(opts, :since, 0)

    run(
      %{action: "wait_results", expect: expect, timeoutMs: timeout, since: since},
      timeout + 30_000
    )
  end

  @doc "프로젝트 다운로드를 누른다. 받은 파일은 Downloads 감시가 가져간다."
  def download, do: run(%{action: "download"}, 60_000)

  @doc "이 프로젝트가 Flow 자동 조종을 쓰는가."
  def auto?(%{pipeline: "flow_auto"}), do: true
  def auto?(_), do: false

  @doc """
  한 단계(붙여넣기 → 생성 → 대기 → 다운로드)를 백그라운드로 돌린다.

  Veo 는 분 단위로 걸린다. MCP 호출이 그동안 붙잡혀 있으면 클라이언트가 먼저 끊는다.
  그래서 진행 상태를 GenerationJob 행에 남기고 `next/1` 은 곧바로 `wait` 를 돌려준다.
  """
  def run_stage_async(project, stage, prompt, expect) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, job} =
      Jobs.record_generation(%{
        project_id: project.id,
        provider: "flow",
        model: stage,
        status: "running",
        requested_at: now
      })

    Task.Supervisor.start_child(VideoCRM.TaskSupervisor, fn ->
      run_stage(job, prompt, expect)
    end)

    {:ok, job}
  end

  defp run_stage(job, prompt, expect) do
    result =
      with {:ok, started} <- paste_and_generate(prompt),
           {:ok, _} <- wait_results(expect, since: started[:results_before] || 0),
           {:ok, _} <- download() do
        :ok
      end

    finish(job, result)
  end

  defp finish(job, :ok) do
    Jobs.finish_generation(job, "done", "")
  end

  defp finish(job, {:error, reason}) do
    Logger.error("Flow 자동 조종 실패: #{reason}")
    Jobs.finish_generation(job, "failed", reason)
  end

  # ── 실행 ────────────────────────────────────────────────────────

  defp run(command, timeout) do
    script = Path.join([:code.priv_dir(:video_crm), "flow_driver", "driver.mjs"])

    if File.exists?(script) do
      execute(script, command, timeout)
    else
      {:error, "driver.mjs 가 없습니다: #{script}"}
    end
  end

  defp execute(script, command, timeout) do
    task =
      Task.async(fn ->
        System.cmd("node", [script, Jason.encode!(command)], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> decode(output, command)
      {:ok, {output, code}} -> {:error, "driver 종료 코드 #{code}: #{String.slice(output, 0, 400)}"}
      nil -> {:error, "driver 응답 없음 (#{div(timeout, 1000)}초)"}
    end
  rescue
    e in ErlangError -> {:error, "node 를 실행할 수 없습니다: #{inspect(e.original)}"}
  end

  # driver 는 마지막 줄에 JSON 을 뱉는다. 앞줄은 node 경고일 수 있다.
  defp decode(output, command) do
    line =
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find(&String.starts_with?(String.trim(&1), "{"))

    case line && Jason.decode(line) do
      {:ok, %{"ok" => true} = result} ->
        {:ok, atomize(result)}

      {:ok, %{"ok" => false, "error" => error}} ->
        Logger.warning("Flow #{command.action} 실패: #{error}")
        {:error, error}

      _ ->
        {:error, "driver 응답을 읽지 못했습니다: #{String.slice(output, 0, 400)}"}
    end
  end

  defp atomize(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
end