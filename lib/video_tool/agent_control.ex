defmodule VideoTool.AgentControl do
  @moduledoc """
  무인 루프를 화면에서 멈춘다.

  **끄는 것만 있다. 켜는 건 없다.**
  고장 났을 때는 누구든 빨리 멈출 수 있어야 하지만, 다시 켜는 건 크레딧이 나가는
  일이라 서버에 들어올 수 있는 사람(키 소지자)만 하게 둔다 — `ssh flow flow-start`.
  화면은 Cloudflare Access 뒤에 있지만, 이메일만 있으면 들어오는 곳이다.

  멈추는 것 세 가지:
    1. systemd 타이머  — 안 끄면 2시간 뒤에 또 깨어난다
    2. 루프 스크립트    — `run-agent.sh`
    3. 에이전트         — `claude --print`

  **돌고 있는 Flow 생성과 ffmpeg 합성은 건드리지 않는다.** 그것들은 이미 크레딧을
  썼거나 거의 끝나가는 일이라, 죽이면 결과만 날아간다. 다음 회수 때 주워온다.
  """

  require Logger

  @doc """
  멈춘다. 무엇을 실제로 멈췄는지 돌려준다.

  리눅스(서버) 전용이다. 윈도우에서는 예약 작업을 쓰므로 여기서 손대지 않는다 —
  잘못 부르면 아무 일도 안 일어난 채 "멈췄다" 고 답하게 되므로 그 사실을 알린다.
  """
  def stop do
    if windows?() do
      %{
        ok: false,
        reason: "이 화면의 정지 버튼은 서버(리눅스)용입니다. 윈도우에서는 예약 작업을 끄세요.",
        stopped: []
      }
    else
      stopped =
        [timer_off(), kill("run-agent.sh"), kill("claude --print")]
        |> Enum.reject(&is_nil/1)

      File.rm(Path.join(File.cwd!(), ".agent.lock"))
      Logger.warning("[agent_control] 무인 루프 정지: #{inspect(stopped)}")

      %{
        ok: true,
        stopped: stopped,
        note:
          "돌던 Flow 생성과 합성은 그대로 끝납니다. 다시 켜려면 서버에서 " <>
            "`ssh flow flow-start auto` 를 쓰세요.",
        still_running: leftovers()
      }
    end
  end

  @doc "지금 루프가 돌고 있나. 화면이 버튼을 보여줄지 정하는 데 쓴다."
  def running? do
    not windows?() and (pgrep?("run-agent.sh") or pgrep?("claude --print") or timer_on?())
  end

  @doc """
  **한 번만** 돌린다. 한 편 만들고 스스로 멈춘다.

  화면에서 켜는 건 여기까지다. 2시간마다 도는 타이머는 화면에 두지 않는다 —
  그건 켜두면 사람 없이 계속 크레딧이 나가는 일이라, 서버에 들어올 수 있는
  사람만 켜게 한다(`ssh flow flow-start auto`).

  `setsid` 로 떼어낸다. 안 그러면 이 LiveView 프로세스에 묶여, 화면을 닫는
  순간 제작이 같이 죽는다.
  """
  @rounds "6"

  def run_once do
    cond do
      windows?() ->
        %{ok: false, reason: "이 버튼은 서버(리눅스)용입니다."}

      pgrep?("run-agent.sh") ->
        %{ok: false, reason: "이미 돌고 있습니다."}

      true ->
        script = Path.join(File.cwd!(), "deploy/linux/run-agent.sh")

        if File.exists?(script) do
          log = Path.join(File.cwd!(), "logs/agent-web.log")

          _ =
            spawn(fn ->
              cmd("setsid", [
                "env",
                "ROUNDS=#{@rounds}",
                "bash",
                "-c",
                "#{script} > #{log} 2>&1 < /dev/null"
              ])
            end)

          Logger.warning("[agent_control] 화면에서 1회 실행 시작")
          Process.sleep(2_500)

          %{
            ok: true,
            note:
              "한 편을 만들고 멈춥니다(최대 #{@rounds}라운드). 발행까지 합니다. " <>
                "계속 돌게 하려면 서버에서 `ssh flow flow-start auto`."
          }
        else
          %{ok: false, reason: "루프 스크립트를 못 찾았습니다: #{script}"}
        end
    end
  end

  # ── 안쪽 ────────────────────────────────────────────────────────

  defp windows?, do: match?({:win32, _}, :os.type())

  # 타이머는 sudo 가 필요하다. sudoers 에 NOPASSWD 가 없으면 조용히 실패하므로
  # 성공했을 때만 목록에 넣는다 — "껐다" 고 거짓말하지 않는다.
  defp timer_off do
    if timer_on?() do
      case cmd("sudo", ~w(systemctl disable --now videocrm-agent.timer)) do
        {_, 0} -> "타이머"
        {out, _} ->
          Logger.error("[agent_control] 타이머를 못 껐다: #{String.slice(out, 0, 200)}")
          nil
      end
    end
  end

  defp timer_on? do
    match?({"enabled\n", 0}, cmd("systemctl", ~w(is-enabled videocrm-agent.timer))) or
      match?({"active\n", 0}, cmd("systemctl", ~w(is-active videocrm-agent.timer)))
  end

  defp kill(pattern) do
    if pgrep?(pattern) do
      cmd("pkill", ["-f", pattern])
      Process.sleep(1_500)
      # TERM 으로 안 죽으면 KILL. 에이전트는 자식 프로세스를 물고 있어 늦게 죽는다.
      if pgrep?(pattern), do: cmd("pkill", ["-9", "-f", pattern])
      pattern
    end
  end

  defp pgrep?(pattern), do: match?({_, 0}, cmd("pgrep", ["-f", pattern]))

  # 죽이지 않고 두는 것들. 화면에 "아직 이건 돕니다" 로 보여준다.
  defp leftovers do
    [{"ffmpeg", "합성"}, {"cloudflared", "터널"}]
    |> Enum.filter(fn {p, _} -> pgrep?(p) end)
    |> Enum.map(fn {_, label} -> label end)
  end

  defp cmd(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: true)
  rescue
    _ -> {"", 1}
  end
end
