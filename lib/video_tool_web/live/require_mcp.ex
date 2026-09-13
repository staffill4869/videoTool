defmodule VideoToolWeb.RequireMCP do
  @moduledoc """
  MCP 를 한 번도 연결한 적이 없으면 안내 화면으로 보낸다.

  **가두지는 않는다.** 연결이 안 되는 원인을 고치려면 설정 화면이 필요한데
  거기까지 막으면 빠져나올 방법이 없다. `?skip_mcp=1` 로 넘어갈 수 있고,
  한 번 넘어가면 그 세션 동안은 다시 묻지 않는다.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  alias VideoTool.AppState

  def on_mount(:default, _params, _session, socket) do
    cond do
      AppState.mcp_ever_connected?() -> {:cont, assign(socket, mcp_gate: :passed)}
      AppState.mcp_gate_skipped?() -> {:cont, assign(socket, mcp_gate: :skipped)}
      true -> {:halt, redirect(socket, to: "/connect")}
    end
  end
end