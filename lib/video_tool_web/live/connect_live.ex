defmodule VideoToolWeb.ConnectLive do
  @moduledoc """
  MCP 연결 안내. 한 번도 붙은 적이 없으면 다른 화면 대신 여기로 보낸다.

  이 앱의 조작은 전부 MCP 로 한다. 화면은 결과를 보는 곳이다.
  MCP 가 안 붙은 채로 화면만 돌아다니면 아무것도 할 수 없는데, 그 사실이 화면에 드러나지 않는다.

  **가두지는 않는다.** 연결이 안 되는 상황을 고치려면 설정 화면에 들어가야 하는데,
  거기까지 막으면 빠져나올 방법이 없어진다. `/settings` 와 이 화면은 게이트 밖에 두고,
  "연결 없이 둘러보기" 도 남겨둔다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.AppState

  @poll 2000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@poll, :check)
    {:ok, assign(socket, status: AppState.mcp_status(), tools: length(VideoTool.MCP.tools()))}
  end

  @impl true
  def handle_info(:check, socket) do
    status = AppState.mcp_status()

    # 방금 붙었으면 바로 들여보낸다. 계속 새로고침하게 만들지 않는다.
    if status.state == :connected and socket.assigns.status.state != :connected do
      {:noreply,
       socket
       |> put_flash(:info, "MCP 가 연결됐습니다 (#{status.client})")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply, assign(socket, status: status)}
    end
  end

  @impl true
  def handle_event("skip", _params, socket) do
    AppState.skip_mcp_gate()
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:connect}>
      <.header>
        먼저 MCP 를 연결하세요
        <:subtitle>
          이 앱의 조작은 전부 MCP 로 합니다. 화면은 결과를 보는 곳입니다.
        </:subtitle>
      </.header>

      <div class={["alert mt-4", badge_class(@status.state)]}>
        <div>
          <div class="font-semibold">{status_text(@status)}</div>
          <div :if={@status.at} class="text-sm opacity-80">
            마지막 연결 {Calendar.strftime(@status.at, "%m-%d %H:%M:%S")} (UTC)
            {if @status.client, do: " · #{@status.client}"}
          </div>
        </div>
      </div>

      <div class="mt-6 grid gap-4 lg:grid-cols-2">
        <div class="card bg-base-200">
          <div class="card-body gap-2 p-4">
            <div class="font-semibold">Claude Code</div>
            <div class="text-sm opacity-70">이 폴더에서 열면 <code class="font-mono">.mcp.json</code> 을 읽습니다.</div>
            <pre class="rounded bg-base-100 p-2 text-xs">{open_snippet()}</pre>
            <div class="text-sm opacity-70">어느 폴더에서든 쓰려면:</div>
            <pre class="rounded bg-base-100 p-2 text-xs">{add_snippet()}</pre>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body gap-2 p-4">
            <div class="font-semibold">Claude Desktop</div>
            <div class="text-sm opacity-70">
              설정 파일은 stdio 만 받아서 <code class="font-mono">mcp-remote</code> 로 중계합니다.
            </div>
            <pre class="rounded bg-base-100 p-2 text-xs">{desktop_config_path()}</pre>
            <pre class="max-h-40 overflow-auto rounded bg-base-100 p-2 text-xs">{desktop_snippet()}</pre>
            <div class="text-xs opacity-60">고친 뒤 Desktop 을 완전히 종료했다 다시 켜야 합니다.</div>
          </div>
        </div>
      </div>

      <div class="mt-6 rounded border border-base-300 p-4 text-sm">
        <div class="font-semibold">붙으면 이 화면이 자동으로 넘어갑니다</div>
        <div class="mt-1 opacity-70">
          2초마다 확인합니다. 새로고침하지 않으셔도 됩니다.
          연결되면 툴 {@tools}개를 쓸 수 있습니다 — 프로젝트 만들기, 대본 저장, 프롬프트 받기,
          성과 집계까지 전부.
        </div>
        <div class="mt-3 flex gap-2">
          <.link navigate={~p"/settings"} class="btn btn-sm">설정으로</.link>
          <button phx-click="skip" class="btn btn-ghost btn-sm">연결 없이 둘러보기</button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # 코드 조각은 HEEx 히어독 밖에서 만든다 — 안에 넣으면 들여쓰기가 어긋난다.
  defp open_snippet, do: "cd C:\\rebase\\videoTool\nclaude"

  defp add_snippet,
    do: "claude mcp add --scope user --transport http videotool http://localhost:4300/mcp"

  defp desktop_config_path, do: "%APPDATA%\\Claude\\claude_desktop_config.json"

  defp desktop_snippet do
    """
    "videotool": {
      "command": "C:\\\\Program Files\\\\nodejs\\\\node.exe",
      "args": [
        "C:\\\\Users\\\\<이름>\\\\AppData\\\\Roaming\\\\npm\\\\node_modules\\\\mcp-remote\\\\dist\\\\proxy.js",
        "http://127.0.0.1:4300/mcp",
        "--allow-http"
      ]
    }
    """
  end

  defp badge_class(:connected), do: "alert-success"
  defp badge_class(:stale), do: "alert-warning"
  defp badge_class(_), do: "alert-info"

  defp status_text(%{state: :connected}), do: "연결됨"
  defp status_text(%{state: :stale}), do: "붙은 적은 있지만 지금은 조용합니다"
  defp status_text(_), do: "아직 연결된 적이 없습니다"
end