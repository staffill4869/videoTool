defmodule VideoToolWeb.MCPController do
  @moduledoc """
  MCP streamable HTTP 엔드포인트. JSON-RPC 2.0 을 그대로 받는다.

  별도 MCP SDK 를 쓰지 않는 이유: 이 서버가 필요한 건 initialize / tools/list /
  tools/call 세 개뿐이고, 그건 컨트롤러 하나로 끝난다.
  """
  use VideoToolWeb, :controller

  alias VideoTool.{AppState, MCP}

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
    # 붙었다는 사실을 남긴다. 화면이 "MCP 를 먼저 연결하세요" 를 언제까지 띄울지 이걸로 판단한다.
    AppState.mcp_seen(params["clientInfo"] || %{})

    agreed =
      case params["protocolVersion"] do
        v when v in @supported -> v
        _ -> @protocol_version
      end

    {:ok,
     %{
       "protocolVersion" => agreed,
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => "videoTool", "version" => version_string()},
       # 붙는 모든 클라이언트가 규칙을 보게 하는 자리. CLAUDE.md 는 Claude Code 만 읽고
       # 데스크톱 앱은 안 읽는다 — 여기 실어야 어느 클라이언트든 받는다.
       "instructions" => instructions()
     }}
  end

  defp dispatch("notifications/" <> _rest, _params), do: :notification
  defp dispatch("ping", _params), do: {:ok, %{}}
  defp dispatch("tools/list", _params), do: {:ok, %{"tools" => MCP.tools()}}

  defp dispatch("tools/call", %{"name" => name} = params) do
    # 툴을 부르는 것도 살아있다는 신호다. initialize 는 세션당 한 번뿐이라
    # 이것까지 세야 "지금 붙어 있나" 를 알 수 있다.
    AppState.touch_mcp()
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
    case :application.get_key(:video_tool, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end

  # 여기 적는 것은 '이 서버를 쓰는 법' 이지 프로젝트 설명이 아니다. 짧게 유지한다 —
  # 길면 클라이언트가 잘라내거나 모델이 흘린다. 자세한 것은 CLAUDE.md 에 있다.
  defp instructions do
    """
    videoTool — 영상 제작 파이프라인 (CRM 아님).
    한 편의 순서: 대본 → 장면 → 허용수치 → CLEAN(글자 없는 이미지) → INFO(인포그래픽)
    → VIDEO(두 이미지 사이를 영상으로) → 나레이션 → 합성 → 발행.

    **이 전체를 당신이 몬다.** 서버는 스스로 밀지 않는다(auto_advance 꺼짐).
    중간에 사람에게 묻지 마라. 오류로 막힐 때만 멈춘다.

    한 편을 끝까지 만드는 절차
    1. run_series(series_id) 로 이번 편을 만든다. 이미 만들어둔 편이 있으면 건너뛴다.
    2. next_job 을 반복해 불러 대본·장면분할·허용수치를 채운다
       (save_script / save_scenes / save_allowed_facts). 더 안 내줄 때까지.
    3. flow_new_project(project_id) — 편마다 새로 연다. 사람에게 열어달라고 하지 마라.
    4. flow_generate(project_id, stage: "clean") → flow_job 으로 끝날 때까지 확인
       → flow_harvest(project_id, stage: "clean"). 받은 장수가 장면 수와 같은지 본다.
    5. 같은 방식으로 stage: "info". INFO 는 CLEAN 을 제자리에서 편집하는 것이라
       화면의 타일 개수가 안 늘 수 있다. 개수 말고 flow_harvest 결과로 판단하라.
    6. 같은 방식으로 stage: "video". 모자라면 한 번만 더 시도하고, 그래도 모자라면
       있는 것으로 다음으로 간다. **같은 단계를 세 번 이상 돌리지 마라 — 크레딧만 나간다.**
    7. 나레이션: **대본 길이를 영상에 먼저 맞춘다.** next_job 의 clip_total_sec 이 실제 영상 길이다.
       대본이 그보다 짧으면 save_script 로 더 써서 맞춘 뒤에 음성을 만든다 —
       짧은 대본으로 만들면 뒷부분이 통째로 무음이 된다 (실측: 영상 120초 / 나레이션 67초).
       그다음 힉스필드 MCP 로 음성을 만들어
       save_narration(project_id, file) 에 파일 경로나 URL 을 넘긴다.
       서버에 TTS 키가 없어 이건 당신만 할 수 있다. 낭독 속도로 길이를 맞추지 마라.
    8. assemble(project_id) 로 합성한다. 클립이 장면의 90% 미만이면 거부한다 — 정상 동작이다.

    편집에서 알아낸 것 (전부 실측)
    - **길이는 영상이 정한다.** Flow 클립은 장면 목표와 무관하게 8초씩 나온다.
      장면 16개면 영상이 120~144초가 된다. 60초로 쓴 대본을 그대로 쓰면 뒤 절반이 빈다.
      그래서 7번이 "대본을 영상 길이에 맞춰 다시 쓴 뒤 TTS" 다. 순서를 지켜라.
    - **클립을 잘라 길이를 맞추지 않는다.** 서버가 클립을 통째로 쓴다 (예전엔 8초를 3초로
      깎아 만든 영상의 60%를 버렸다). 길이는 결과지 목표가 아니다.
    - 서버가 알아서 하는 것 — 굳이 지시하지 마라:
      9:16 이면 1080x1920 판으로 렌더 · 자막을 세로 치수로(52pt, 줄바꿈 켬) ·
      클립의 배경음을 18%로 깔고 나레이션을 위에 얹기 · 나레이션이 짧으면 무음으로 패딩.
    - 완성본은 projects/<id>/final.mp4 다. master_nosub.mp4 는 자막 없는 판이라
      다른 언어판·세로본이 재사용한다. 지우지 마라.
    9. 발행은 사람이 지시했을 때만 publish(confirm: true). 자동 발행하지 마라.

    단계마다 확인할 것 (건너뛰지 마라)
    - **CLEAN 이 나오면 이미지를 직접 열어 본다.** 내용이 대본과 맞는지, 장면 배정이 맞는지.
      여기가 유일하게 사람(또는 당신)이 눈으로 봐야 하는 곳이다 — CLEAN 은 대조할 기준이 없어
      화면 순서대로 배정되는데 Flow 는 요청 순서대로 내놓지 않는다. 틀리면 손으로 바로잡는다.
    - 배정 신뢰도 0.99 는 "클립이 자기 이미지와 맞는다" 는 뜻이지 "그림이 대본과 맞는다" 가 아니다.
    - 실패가 조용히 온다: 작업이 done 인데 자산 0개, 프롬프트는 맞는데 그림이 딴것.
      단계가 끝날 때마다 개수와 화면비를 숫자로 확인하고 사용자에게 한 줄로 보고한다.

    막히면
    - Flow 탭이 홈·소개 화면이면 flow_new_project 로 직접 편집기를 연다.
    - 크레딧 승인 창은 드라이버가 '항상 승인' 을 누른다. 사람을 부르지 마라.
    - 화면 제어(마우스·키보드)를 쓰지 마라. MCP 도구만 쓴다.
    - 사람이 필요한 것은 유튜브 OAuth 하나뿐이다. channel_status 가 connected:false 면 거기서 멈춘다.

    대본 규칙
    - 쓰기 전에 estimate_length 로 길이를 확인한다. 목표를 넘기면 TTS 가 두 배로 나온다.
    - 길이가 안 맞으면 낭독 속도가 아니라 대본 글자 수를 고친다.
    - 허용 수치를 반드시 채운다. 없으면 INFO 에서 대본에 없는 숫자가 화면에 그려진다.
    - create_project 에서 aspect 를 생략하면 그림체 기본값 16:9 가 된다. 세로면 "9:16" 을 넘겨라.

    자세한 함정은 프로젝트 루트의 CLAUDE.md 에 있다.
    """
  end
end