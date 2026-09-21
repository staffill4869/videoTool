defmodule VideoToolWeb.ProjectLive.Index do
  @moduledoc """
  프로젝트 목록.

  한 줄에 한 편. 예전엔 `상태` 글자와 `3/8` 숫자가 칸칸이 흩어져 있어서, 어디까지 왔는지
  알려면 칸을 좌우로 훑어야 했다. 지금은 눈금 하나로 읽고, **누가 붙어 있는지**를 같은
  줄에서 본다 — 그게 "왜 안 넘어가지" 의 답인 경우가 대부분이다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.{Progress, Projects}

  @filters [
    {:all, "전체"},
    {:running, "돌고 있음"},
    {:gate, "내 확인"},
    {:blocked, "막힘"},
    {:done, "발행됨"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "프로젝트", filter: :all) |> load()}
  end

  defp load(socket), do: assign(socket, rows: Progress.rows())

  @impl true
  def handle_event("filter", %{"kind" => kind}, socket) do
    {:noreply, assign(socket, filter: String.to_existing_atom(kind))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, project} <- Projects.get_project(id),
         {:ok, _} <- Projects.delete_project(project) do
      {:noreply,
       socket
       |> put_flash(:info, "'#{project.title}' 을(를) 지웠습니다. 만들어진 파일은 디스크에 남아 있습니다.")
       |> load()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, "지우지 못했습니다: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :shown, filtered(assigns.rows, assigns.filter))

    ~H"""
    <Layouts.app flash={@flash} active={:projects}>
      <.header>
        프로젝트
        <:subtitle>
          조작은 MCP 로 한다. 이 화면은 어디까지 왔는지와 누가 붙어 있는지를 보는 곳이다.
        </:subtitle>
      </.header>

      <div class="flex flex-wrap gap-2">
        <button
          :for={{kind, label} <- filters()}
          type="button"
          phx-click="filter"
          phx-value-kind={kind}
          class={[
            "inline-flex min-h-9 items-center gap-2 rounded-full border px-3.5 text-[13px]",
            (@filter == kind && "border-base-content bg-base-content font-semibold text-base-100") ||
              "border-base-300 bg-base-100 hover:bg-base-200"
          ]}
        >
          <span :if={kind != :all} class={["size-2 rounded-full", chip_dot(kind)]} />
          {label} {tally(@rows, kind)}
        </button>
      </div>

      <div
        :if={@shown == []}
        class="rounded-lg border border-base-300 bg-base-100 p-6 text-base-content/60"
      >
        <span :if={@rows == []}>
          아직 프로젝트가 없습니다. MCP 의 <code class="font-mono">create_project</code> 로 만드세요.
        </span>
        <span :if={@rows != []}>이 갈래에 해당하는 영상이 없습니다.</span>
      </div>

      <div :if={@shown != []} class="overflow-hidden rounded-lg border border-base-300 bg-base-100">
        <div class="hidden items-center gap-4 border-b border-base-300 bg-base-200 px-5 py-2 text-[11px] font-semibold text-base-content/60 lg:flex">
          <span class="w-64 shrink-0">영상</span>
          <span class="grow">진행</span>
          <span class="w-44 shrink-0">지금</span>
          <span class="w-20 shrink-0">누가</span>
          <span class="w-28 shrink-0"></span>
        </div>

        <div
          :for={row <- @shown}
          class="flex flex-col gap-3 border-b border-base-300 px-5 py-4 last:border-0 lg:flex-row lg:items-center lg:gap-4"
        >
          <div class="flex w-full shrink-0 items-center gap-3 lg:w-64">
            <span class="h-10 w-1 shrink-0 rounded-full" style={"background:#{row.color}"} />
            <div class="min-w-0">
              <.link
                navigate={~p"/projects/#{row.id}"}
                class="block truncate font-semibold hover:underline"
              >
                {row.title}
              </.link>
              <div class="mt-0.5 truncate text-[11px] text-base-content/60">
                {row.aspect} · 장면 {row.scenes} · {row.voice}
              </div>
            </div>
          </div>

          <.pipeline steps={row.steps} ticks={row.ticks} class="min-w-0 grow" />

          <div class="w-full shrink-0 lg:w-44">
            <div class="text-xs font-medium">{row.now}</div>
            <div class="mt-0.5 font-mono text-[11px] text-base-content/50">{row.since}</div>
          </div>

          <div class="w-full shrink-0 lg:w-20">
            <.owner owner={row.owner} />
          </div>

          <div class="flex w-full shrink-0 items-center gap-2 lg:w-28 lg:justify-end">
            <.link navigate={~p"/projects/#{row.id}"} class="btn btn-sm">열기</.link>
            <button
              phx-click="delete"
              phx-value-id={row.id}
              data-confirm={"'#{row.title}' 을(를) 지웁니다. 대본·장면·자산 기록이 함께 사라집니다. (파일은 디스크에 남습니다)"}
              class="btn btn-ghost btn-sm text-error"
            >
              삭제
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp filters, do: @filters

  defp filtered(rows, :all), do: rows
  defp filtered(rows, kind), do: Enum.filter(rows, &(&1.kind == kind))

  defp tally(rows, :all), do: length(rows)
  defp tally(rows, kind), do: Enum.count(rows, &(&1.kind == kind))

  defp chip_dot(:running), do: "bg-warning"
  defp chip_dot(:gate), do: "border-2 border-warning"
  defp chip_dot(:blocked), do: "bg-error"
  defp chip_dot(:done), do: "bg-success"
  defp chip_dot(_), do: "bg-base-300"
end
