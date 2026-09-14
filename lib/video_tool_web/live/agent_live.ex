defmodule VideoToolWeb.AgentLive do
  @moduledoc """
  무인 루프 감시 화면.

  루프는 조용히 멈춘다 — Chrome 이 죽거나, 예약이 꺼졌거나, 에이전트가 권한에 막혀
  아무 일도 못 하고 끝나도 어디에도 표시가 없었다. 이 화면은 그 셋을 한눈에 보여주고,
  프로젝트마다 "지금 무엇을 기다리는 중인지" 를 한 줄로 적는다.

  5초마다 새로 읽는다. 예약 작업 상태만 PowerShell 을 부르므로 그만 15초마다 읽는다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.AgentStatus

  @fast :timer.seconds(5)
  @slow :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@fast, self(), :tick)
      :timer.send_interval(@slow, self(), :tick_slow)
    end

    {:ok, socket |> assign(page_title: "에이전트", shell: nil) |> load() |> load_shell()}
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
    assign(socket, shell: Map.take(snap, [:task, :running, :chrome, :log]))
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info(:tick_slow, socket), do: {:noreply, load_shell(socket)}

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
          <span class="font-mono text-xs text-base-content/50">{@at} UTC · 5초마다 갱신</span>
        </div>

        <div :if={@shell} class="grid gap-3 sm:grid-cols-3">
          <div class="rounded-lg border border-base-300 p-3">
            <div class="text-xs text-base-content/60">지금 돌고 있나</div>
            <div class="mt-1 flex items-center gap-2">
              <span class={["inline-block h-2.5 w-2.5 rounded-full", dot(@shell.running[:running])]}></span>
              <span class="font-semibold">
                {if @shell.running[:running], do: "작업 중", else: "쉬는 중"}
              </span>
            </div>
            <div :if={@shell.running[:running]} class="mt-1 text-xs text-base-content/60">
              {@shell.running[:since_min]}분째
            </div>
            <div :if={@shell.running[:stale]} class="mt-1 text-xs text-warning">
              1시간 넘게 잠겨 있습니다 — 죽은 잠금일 수 있습니다
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

        <div :if={@shell && @shell.log != []} class="rounded-lg border border-base-300 p-3">
          <div class="mb-2 text-xs text-base-content/60">최근 루프 기록</div>
          <pre class="overflow-x-auto font-mono text-[11px] leading-relaxed text-base-content/70"><%= Enum.join(@shell.log, "\n") %></pre>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
