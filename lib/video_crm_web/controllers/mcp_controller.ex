defmodule VideoCRMWeb.MCPController do
  @moduledoc """
  MCP streamable HTTP 엔드포인트. JSON-RPC 2.0 을 그대로 받는다.

  별도 MCP SDK 를 쓰지 않는 이유: 이 서버가 필요한 건 initialize / tools/list /
  tools/call 세 개뿐이고, 그건 컨트롤러 하나로 끝난다.
  """
  use VideoCRMWeb, :controller

  alias VideoCRM.MCP

  # 클라이언트가 보낸 버전을 우리가 알면 그대로 받아주고, 모르면 우리 기본값을 알려준다.
  # **거절하지 않는다** — MCP 규격상 버전 합의는 서버가 지원 버전을 제시하고 클라이언트가
  # 판단하는 것이다. 거절했더니 `2024-11-05` 를 보내는 클라이언트가 아예 못 붙었다.
  @protocol_version "2025-06-18"
  @supported ["2024-11-05", "2025-03-26", "2025-06-18"]

  def handle(conn, %{"method" => method} = body) do
    id = body["id"]

    case dispatch(method, body["params"] || %{}) do
      :notification -> send_resp(conn, 202, "")
      {:ok, result} -> json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
      {:error, code, message} -> json(conn, error_body(id, code, message))
    end
  end

  def handle(conn, _body) do
    json(conn, error_body(nil, -32600, "jsonrpc 요청이 아닙니다"))
  end

  defp dispatch("initialize", params) do
    agreed =
      case params["protocolVersion"] do
        v when v in @supported -> v
        _ -> @protocol_version
      end

    {:ok,
     %{
       "protocolVersion" => agreed,
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => "videoCRM", "version" => version_string()}
     }}
  end

  defp dispatch("notifications/" <> _rest, _params), do: :notification
  defp dispatch("ping", _params), do: {:ok, %{}}
  defp dispatch("tools/list", _params), do: {:ok, %{"tools" => MCP.tools()}}

  defp dispatch("tools/call", %{"name" => name} = params) do
    result = MCP.call(name, params["arguments"])

    {:ok,
     %{
       "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
       "isError" => result[:ok] == false
     }}
  end

  defp dispatch("tools/call", _params), do: {:error, -32602, "name 이 없습니다"}
  defp dispatch(method, _params), do: {:error, -32601, "지원하지 않는 메서드: #{method}"}

  defp error_body(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp version_string do
    case :application.get_key(:video_crm, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end
end