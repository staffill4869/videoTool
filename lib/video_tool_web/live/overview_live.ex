defmodule VideoToolWeb.OverviewLive do
  @moduledoc """
  홈 — 현황판.

  왜 이 화면이 생겼나: 홈이 프로젝트 표였고 `/dashboard` 는 조회수였다. 그래서 정작
  **"지금 뭐가 돌고 있고, 뭐가 나를 기다리나"** 를 볼 자리가 어디에도 없었다.
  단계별 숫자를 화면 세 곳에서 주워 머리로 합쳐야 했고, 그러다 보니 사람을 기다리는
  일이 몇 시간씩 방치됐다.

  네 덩이만 본다: 돌고 있는 것 · 내 손이 필요한 것 · 막힌 것 · 무인 루프.

  주기는 넉넉히 잡는다. 10초·20초다. 15~20초마다 psql·curl 을 여러 개 띄워
  서버를 두 번 죽인 적이 있다 — 감시가 대상을 갉아먹으면 안 된다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.{AgentStatus, Progress}

  @rows :timer.seconds(10)
  @shell :timer.seconds(20)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@rows, self(), :tick)
      :timer.send_interval(@shell, self(), :tick_shell)
    end

    {:ok, socket |> assign(page_title: "현황") |> load() |> load_shell()}
  end

  defp load(socket) do
    rows = Progress.rows()

    assign(socket,
      rows: rows,
      running: Enum.filter(rows, &(&1.kind == :running)),
      blocked: Enum.filter(rows, &(&1.kind == :blocked)),
      waiting: Enum.filter(rows, &(&1.kind == :gate)),
      counts: Enum.frequencies_by(rows, & &1.kind),
      at: Time.utc_now() |> Time.truncate(:second)
    )
  end

  defp load_shell(socket), do: assign(socket, shell: AgentStatus.light())

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info(:tick_shell, socket), do: {:noreply, load_shell(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:overview}>
      <.header>
        현황
        <:subtitle>지금 무엇이 돌고 있고, 무엇이 나를 기다리는지</:subtitle>
        <:actions>
          <span class="font-mono text-xs text-base-content/50">{@at} 기준</span>
        </:actions>
      </.header>

      <div class="grid grid-cols-2 gap-3 md:grid-cols-4">
        <.tile
          label="돌고 있음"
          value={count(@counts, :running)}
          note="Flow · 에이전트"
          tone={(count(@counts, :running) > 0 && :running) || :neutral}
        />
        <.tile
          label="내 손이 필요함"
          value={count(@counts, :gate)}
          note="자동으로 안 풀림"
          tone={(count(@counts, :gate) > 0 && :gate) || :neutral}
        />
        <.tile
          label="막힘"
          value={count(@counts, :blocked)}
          note="작업이 실패로 끝남"
          tone={(count(@counts, :blocked) > 0 && :blocked) || :neutral}
        />
        <.tile label="발행됨" value={count(@counts, :done)} note="누적" tone={:done} />
      </div>

      <div class="grid gap-5 lg:grid-cols-[1fr_360px]">
        <div class="min-w-0 space-y-5">
          <section class="space-y-3">
            <h2 class="text-sm font-bold">지금 돌고 있는 것</h2>

            <div
              :if={@running == [] and @blocked == []}
              class="rounded-lg border border-base-300 bg-base-100 p-4 text-sm text-base-content/60"
            >
              도는 것이 없습니다. 아래 「내 손이 필요한 것」 을 비우면 서버가 다음 편을 집어갑니다.
            </div>

            <.running_card :for={row <- @running} row={row} />
            <.blocked_card :for={row <- @blocked} row={row} />
          </section>

          <section class="space-y-3">
            <h2 class="text-sm font-bold">내 손이 필요한 것</h2>

            <div
              :if={@waiting == []}
              class="rounded-lg border border-base-300 bg-base-100 p-4 text-sm text-base-content/60"
            >
              없습니다. 전부 자동으로 넘어갑니다.
            </div>

            <.link
              :for={row <- @waiting}
              navigate={~p"/projects/#{row.id}"}
              class="flex items-center gap-3 rounded-lg border border-base-300 bg-base-100 p-3 transition hover:bg-base-200"
            >
              <span class="shrink-0 rounded-md bg-base-content px-2 py-1 text-[10px] font-semibold text-base-100">
                {gate_tag(row.status)}
              </span>
              <div class="min-w-0 grow">
                <div class="truncate text-sm font-semibold">{row.title}</div>
                <div class="mt-0.5 text-xs text-base-content/60">{gate_why(row)}</div>
              </div>
              <span class="shrink-0 font-mono text-xs text-base-content/50">{row.since}</span>
            </.link>
          </section>
        </div>

        <div class="min-w-0 space-y-5">
          <section class="space-y-3">
            <h2 class="text-sm font-bold">무인 루프</h2>

            <div class="space-y-3 rounded-lg border border-base-300 bg-base-100 p-4">
              <div class="flex items-center gap-2">
                <span class={[
                  "size-2.5 rounded-full",
                  (@shell.activity[:working?] && "bg-success") || "bg-base-300"
                ]} />
                <span class="grow text-sm font-semibold">
                  {(@shell.activity[:working?] && "돌고 있습니다") || "쉬는 중"}
                </span>
                <span :if={@shell.running[:running]} class="font-mono text-xs text-base-content/60">
                  {@shell.running.since_min}분째
                </span>
              </div>

              <dl class="space-y-1.5 border-t border-base-300 pt-3 text-xs">
                <div class="flex gap-2">
                  <dt class="w-20 shrink-0 text-base-content/60">잠금 파일</dt>
                  <dd>{(@shell.running[:running] && ".agent.lock 살아 있음") || "없음"}</dd>
                </div>
                <div class="flex gap-2">
                  <dt class="w-20 shrink-0 text-base-content/60">Chrome</dt>
                  <dd>{(@shell.chrome.ok && "CDP 붙음") || "안 붙음"}</dd>
                </div>
                <div class="flex gap-2">
                  <dt class="w-20 shrink-0 text-base-content/60">마지막 도구</dt>
                  <dd>{last_tool(@shell.activity)}</dd>
                </div>
              </dl>

              <.link navigate={~p"/agent"} class="link text-xs">예약 작업까지 보기 →</.link>
            </div>
          </section>

          <section :if={@shell.log != []} class="space-y-3">
            <h2 class="text-sm font-bold">서버가 마지막으로 한 일</h2>
            <div class="space-y-1 rounded-lg border border-base-300 bg-base-200 p-3 font-mono text-[11px] leading-relaxed">
              <div :for={line <- @shell.log} class="truncate text-base-content/70">{line}</div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── 조각 ──────────────────────────────────────────────────────

  attr :row, :map, required: true

  defp running_card(assigns) do
    ~H"""
    <div class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-4">
      <div class="flex items-start gap-2.5">
        <span class="mt-1.5 size-2.5 shrink-0 rounded-full" style={"background:#{@row.color}"} />
        <div class="min-w-0 grow">
          <.link navigate={~p"/projects/#{@row.id}"} class="font-semibold hover:underline">
            {@row.title}
          </.link>
          <div class="mt-0.5 text-xs text-base-content/60">
            장면 {@row.scenes} · {@row.aspect} · {@row.voice}
          </div>
        </div>
        <.owner owner={@row.owner} />
      </div>

      <.pipeline steps={@row.steps} ticks={@row.ticks} />

      <div class="flex items-center gap-3 border-t border-base-300 pt-3">
        <span class="grow text-sm">{@row.now}</span>
        <span class="font-mono text-xs text-base-content/50">{@row.since}</span>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true

  defp blocked_card(assigns) do
    ~H"""
    <div class="flex items-center gap-3 rounded-lg border border-error/40 bg-error/5 p-3">
      <span class="size-2.5 shrink-0 rounded-full bg-error" />
      <div class="min-w-0 grow">
        <.link navigate={~p"/projects/#{@row.id}"} class="text-sm font-semibold hover:underline">
          {@row.title}
        </.link>
        <div class="mt-0.5 text-xs text-base-content/70">{@row.now} · {@row.since}</div>
      </div>
      <.link navigate={~p"/projects/#{@row.id}"} class="btn btn-sm">열기</.link>
    </div>
    """
  end

  # ── 말 ────────────────────────────────────────────────────────

  defp count(counts, kind), do: Map.get(counts, kind, 0)

  defp gate_tag("clean_done"), do: "눈으로"
  defp gate_tag(_), do: "사람만"

  defp gate_why(%{status: "clean_done", scenes: n}),
    do: "CLEAN #{n}장이 대본과 맞는지 봅니다. 배정 신뢰도는 그걸 보장하지 않습니다"

  defp gate_why(%{status: "assembled"}), do: "합성까지 끝났습니다. 유튜브 동의는 사람만 할 수 있습니다"
  defp gate_why(row), do: row.now

  defp last_tool(%{last_active: %{"tool" => tool, "ago_sec" => sec}}), do: "#{tool} · #{ago(sec)}"
  defp last_tool(_), do: "없음"

  defp ago(nil), do: "?"
  defp ago(sec) when sec < 60, do: "#{sec}초 전"
  defp ago(sec) when sec < 3600, do: "#{div(sec, 60)}분 전"
  defp ago(sec), do: "#{div(sec, 3600)}시간 전"
end
