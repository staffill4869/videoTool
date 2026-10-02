defmodule VideoToolWeb.AgentLive do
  @moduledoc """
  무인 루프 감시 화면.

  루프는 조용히 멈춘다 — Chrome 이 죽거나, 예약이 꺼졌거나, 에이전트가 권한에 막혀
  아무 일도 못 하고 끝나도 어디에도 표시가 없었다. 이 화면은 그 셋을 한눈에 보여주고,
  프로젝트마다 "지금 무엇을 기다리는 중인지" 를 한 줄로 적는다.

  5초마다 새로 읽는다. 예약 작업 상태만 PowerShell 을 부르므로 그만 15초마다 읽는다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.{AgentControl, AgentStatus}

  @fast :timer.seconds(5)
  @slow :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@fast, self(), :tick)
      :timer.send_interval(@slow, self(), :tick_slow)
    end

    {:ok,
     socket
     |> assign(
       page_title: "에이전트",
       shell: nil,
       confirm_stop: false,
       stop_result: nil,
       confirm_run: false,
       run_result: nil,
       loop_running: AgentControl.running?()
     )
     |> load()
     |> load_shell()}
  end

  # 정지는 한 번에 안 되게 한다. 이 화면은 이메일만 있으면 들어오는 곳이고,
  # 잘못 누르면 밤새 돌던 제작이 끊긴다.
  @impl true
  def handle_event("ask_stop", _, socket), do: {:noreply, assign(socket, confirm_stop: true)}
  def handle_event("cancel_stop", _, socket), do: {:noreply, assign(socket, confirm_stop: false)}

  def handle_event("stop", _, socket) do
    r = AgentControl.stop()

    {:noreply,
     socket
     |> assign(confirm_stop: false, stop_result: r)
     |> load_shell()}
  end

  # 한 번만 돌리기. 자동(타이머)은 화면에 두지 않는다 — 그건 키 있는 사람만.
  def handle_event("ask_run", _, socket), do: {:noreply, assign(socket, confirm_run: true)}
  def handle_event("cancel_run", _, socket), do: {:noreply, assign(socket, confirm_run: false)}

  def handle_event("run_once", _, socket) do
    r = AgentControl.run_once()

    {:noreply,
     socket
     |> assign(confirm_run: false, stop_result: nil, run_result: r)
     |> load_shell()}
  end

  defp load(socket) do
    assign(socket,
      projects: AgentStatus.projects(),
      at: Time.utc_now() |> Time.truncate(:second)
    )
  end

  # PowerShell·HTTP 를 타는 것들은 따로 돌린다. 5초마다 부르면 화면이 버벅인다.
  defp load_shell(socket) do
    snap = AgentStatus.snapshot()

    assign(socket,
      shell: Map.take(snap, [:task, :running, :chrome, :log, :activity]),
      loop_running: AgentControl.running?()
    )
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info(:tick_slow, socket), do: {:noreply, load_shell(socket)}

  defp ago(nil), do: "?"
  defp ago(sec) when sec < 60, do: "#{sec}초 전"
  defp ago(sec) when sec < 3600, do: "#{div(sec, 60)}분 전"
  defp ago(sec), do: "#{div(sec, 3600)}시간 전"

  defp dot(true), do: "bg-success"
  defp dot(false), do: "bg-error"

  defp stage_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <span
        :for={{label, have, want} <- @steps}
        class={[
          "rounded px-1.5 py-0.5 text-[11px] font-mono",
          have >= want and want > 0 && "bg-success/20 text-success-content",
          (have < want or want == 0) && "bg-base-300 text-base-content/60"
        ]}
        title={label}
      >
        {label}{have}
      </span>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:agent}>
      <div class="space-y-4">
        <div class="flex items-baseline justify-between">
          <div>
            <h1 class="text-2xl font-bold">에이전트</h1>
            <p class="mt-1 text-sm text-base-content/70">
              무인 루프가 살아 있는지, 지금 무엇을 하고 있는지.
            </p>
          </div>
          <div class="flex items-center gap-3">
            <span class="font-mono text-xs text-base-content/50">{@at} UTC · 5초마다 갱신</span>

            <%!-- 화면에서 할 수 있는 건 **끄기**와 **한 번만 돌리기** 두 가지다.
                  "2시간마다 자동" 은 일부러 안 둔다 — 켜두면 사람 없이 계속 크레딧이
                  나가는 일이라, 서버에 들어올 수 있는 사람만 켜게 한다
                  (ssh flow flow-start auto). 둘 다 확인 한 단계를 거친다. --%>
            <button
              :if={@loop_running and !@confirm_stop}
              type="button"
              phx-click="ask_stop"
              class="btn btn-sm btn-outline btn-error"
            >
              무인 제작 끄기
            </button>

            <div :if={@confirm_stop} class="flex items-center gap-2">
              <span class="text-xs text-base-content/70">지금 돌던 제작이 끊깁니다.</span>
              <button type="button" phx-click="stop" class="btn btn-sm btn-error">끕니다</button>
              <button type="button" phx-click="cancel_stop" class="btn btn-sm btn-ghost">취소</button>
            </div>

            <button
              :if={!@loop_running and !@confirm_run}
              type="button"
              phx-click="ask_run"
              class="btn btn-sm btn-outline btn-primary"
            >
              한 번 돌리기
            </button>

            <div :if={@confirm_run} class="flex items-center gap-2">
              <span class="text-xs text-base-content/70">한 편 만들고 멈춥니다. 크레딧이 나갑니다.</span>
              <button type="button" phx-click="run_once" class="btn btn-sm btn-primary">돌립니다</button>
              <button type="button" phx-click="cancel_run" class="btn btn-sm btn-ghost">취소</button>
            </div>
          </div>
        </div>

        <div
          :if={@stop_result}
          class={["rounded-lg border p-3 text-sm",
                  @stop_result.ok && "border-warning bg-warning/10" || "border-error bg-error/10"]}
        >
          <div :if={@stop_result.ok} class="font-semibold">
            무인 제작을 껐습니다{if @stop_result.stopped == [],
              do: " (이미 멈춰 있었습니다)",
              else: " — " <> Enum.join(@stop_result.stopped, " · ")}
          </div>
          <div :if={!@stop_result.ok} class="font-semibold">{@stop_result.reason}</div>
          <div :if={@stop_result.ok} class="mt-1 text-xs text-base-content/70">
            {@stop_result.note}
          </div>
          <div :if={@stop_result.ok and @stop_result.still_running != []} class="mt-1 text-xs text-base-content/70">
            아직 도는 것: {Enum.join(@stop_result.still_running, " · ")} — 끝나게 두는 게 낫습니다
          </div>
        </div>

        <div
          :if={@run_result}
          class={["rounded-lg border p-3 text-sm",
                  @run_result.ok && "border-info bg-info/10" || "border-error bg-error/10"]}
        >
          <div class="font-semibold">
            {if @run_result.ok, do: "제작을 시작했습니다", else: @run_result.reason}
          </div>
          <div :if={@run_result.ok} class="mt-1 text-xs text-base-content/70">
            {@run_result.note}
          </div>
        </div>

        <div :if={@shell} class="grid gap-3 sm:grid-cols-3">
          <div class="rounded-lg border border-base-300 p-3">
            <div class="text-xs text-base-content/60">지금 돌고 있나</div>
            <div class="mt-1 flex items-center gap-2">
              <span class={["inline-block h-2.5 w-2.5 rounded-full", dot(@shell.activity[:working?])]}></span>
              <span class="font-semibold">
                {if @shell.activity[:working?], do: "작업 중", else: "조용함"}
              </span>
            </div>
            <div :if={@shell.activity[:last_active]} class="mt-1 font-mono text-[11px] text-base-content/60">
              {@shell.activity.last_active["tool"]} · {ago(@shell.activity.last_active["ago_sec"])}
            </div>
            <div :if={!@shell.activity[:last_active]} class="mt-1 text-xs text-base-content/50">
              아직 호출 기록 없음
            </div>
            <div :if={@shell.running[:running]} class="mt-1 text-[11px] text-base-content/50">
              Windows 루프도 도는 중 ({@shell.running[:since_min]}분째)
            </div>
          </div>

          <div class="rounded-lg border border-base-300 p-3">
            <div class="text-xs text-base-content/60">예약</div>
            <div class="mt-1 flex items-center gap-2">
              <span class={[
                "inline-block h-2.5 w-2.5 rounded-full",
                dot(@shell.task[:registered] && @shell.task[:state] in ["Ready", "Running"])
              ]}>
              </span>
              <span class="font-semibold">
                {cond do
                  !@shell.task[:registered] -> "등록 안 됨"
                  @shell.task[:state] == "Disabled" -> "꺼짐"
                  true -> @shell.task[:state]
                end}
              </span>
            </div>
            <div :if={@shell.task[:next_run]} class="mt-1 font-mono text-[11px] text-base-content/60">
              다음 {@shell.task[:next_run]}
            </div>
          </div>

          <div class="rounded-lg border border-base-300 p-3">
            <div class="text-xs text-base-content/60">Flow 용 Chrome</div>
            <div class="mt-1 flex items-center gap-2">
              <span class={["inline-block h-2.5 w-2.5 rounded-full", dot(@shell.chrome[:ok])]}></span>
              <span class="font-semibold">{if @shell.chrome[:ok], do: "붙음", else: "끊김"}</span>
            </div>
            <div class="mt-1 truncate font-mono text-[11px] text-base-content/60">
              {@shell.chrome[:browser] || "포트 9222 응답 없음"}
            </div>
          </div>
        </div>

        <div class="overflow-x-auto rounded-lg border border-base-300">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>#</th>
                <th>제목</th>
                <th>단계</th>
                <th>지금</th>
                <th>발행</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @projects} class={p.job && p.job.status == "running" && "bg-primary/5"}>
                <td class="font-mono text-xs">{p.id}</td>
                <td class="max-w-[22rem] truncate">{p.title}</td>
                <td>
                  <.stage_bar steps={[
                    {"장면", p.scenes, 1},
                    {"CLEAN", p.clean, p.scenes},
                    {"INFO", p.info, p.scenes},
                    {"VIDEO", p.clip, p.scenes},
                    {"완성", p.renders, 1}
                  ]} />
                </td>
                <td class={[
                  "text-sm",
                  p.job && p.job.status == "running" && "font-semibold text-primary"
                ]}>
                  {p.now}
                </td>
                <td>
                  <span :if={p.published} class="badge badge-success badge-sm">올림</span>
                  <span :if={!p.published} class="text-xs text-base-content/40">—</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@shell && @shell.activity[:recent] not in [nil, []]} class="rounded-lg border border-base-300 p-3">
          <div class="mb-2 text-xs text-base-content/60">최근 도구 호출 — 누가 몰든 여기에 남습니다</div>
          <div class="flex flex-wrap gap-1">
            <span
              :for={e <- Enum.take(@shell.activity.recent, 12)}
              class={[
                "rounded px-1.5 py-0.5 font-mono text-[11px]",
                e["active"] && "bg-primary/15 text-primary",
                !e["active"] && "bg-base-300 text-base-content/50"
              ]}
              title={e["at"]}
            >
              {e["tool"]} · {ago(e["ago_sec"])}
            </span>
          </div>
        </div>

        <div :if={@shell && @shell.log != []} class="rounded-lg border border-base-300 p-3">
          <div class="mb-2 text-xs text-base-content/60">최근 루프 기록</div>
          <pre class="overflow-x-auto font-mono text-[11px] leading-relaxed text-base-content/70"><%= Enum.join(@shell.log, "\n") %></pre>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
