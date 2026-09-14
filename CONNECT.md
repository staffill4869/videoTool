# videoTool MCP 연결

서버가 떠 있어야 한다. `C:\rebase\videoCRM\restart.ps1` 로 띄운다 (포트 4300).

> 폴더 이름은 **videoCRM** 이다. `C:\rebase\videoTool` 은 빈 껍데기라 거기서 열면 아무것도 안 붙는다.

| 엔드포인트 | 무엇 |
|---|---|
| `http://localhost:4300/mcp` | **videotool** — 이 앱의 툴 20개 (next / save_scenes / ingest / publish …) |
| `http://localhost:4300/tidewave/mcp` | **tidewave** — 개발용 (SQL 조회 · 로그 · 코드 평가) |

프로토콜은 MCP streamable HTTP (JSON-RPC 2.0). 지원 버전은 `2025-03-26` 이상.

---

## 1. Claude Code (권장)

`C:\rebase\videoCRM` 에서 열기만 하면 된다. 폴더의 `.mcp.json` 을 읽고 승인 여부를 묻는다.

```powershell
cd C:\rebase\videoCRM
claude
```

다른 폴더에서도 쓰려면 사용자 범위로 등록한다.

```powershell
claude mcp add --scope user --transport http videocrm http://localhost:4300/mcp
claude mcp add --scope user --transport http tidewave http://localhost:4300/tidewave/mcp
claude mcp list
```

### 손으로 넣고 싶으면

`claude mcp add` 가 쓰는 파일은 **`C:\Users\<사용자>\.claude.json`** 이다.
맨 위(프로젝트별 구역 말고 최상위)의 `mcpServers` 에 이 두 줄을 넣는다.

```json
{
  "mcpServers": {
    "videocrm": {
      "type": "http",
      "url": "http://127.0.0.1:4300/mcp"
    },
    "tidewave": {
      "type": "http",
      "url": "http://127.0.0.1:4300/tidewave/mcp"
    }
  }
}
```

**이름은 `videocrm` 으로 맞춘다.** 도구 이름이 `mcp__videocrm__flow_generate` 처럼 이름을
앞에 달고 나오는데, 무인 루프의 허용 목록(`.claude/settings.local.json`)이 그 이름으로 적혀
있어서 다르게 붙이면 목록에 없는 도구가 되어 전부 거부된다.

넣고 나서 `claude` 를 다시 띄우면 붙는다. `claude mcp list` 로 확인한다.

## 2. Claude Desktop

설정 → 커넥터 → 사용자 지정 커넥터 추가 → URL 에 `http://localhost:4300/mcp`.

로컬 주소라 Desktop 이 거부하면 Claude Code 를 쓰거나 터널을 붙여야 한다.
터널을 쓸 거면 **인증 없이 열지 말 것** — 이 서버는 DB 를 그대로 조작한다.

## 3. Codex · 그 외 MCP 클라이언트

streamable HTTP 를 지원하면 URL 만 넣으면 된다. 지원하지 않으면 stdio 브리지가 필요하다.

---

## 잘 붙었는지 확인

```powershell
$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
Invoke-RestMethod -Uri http://localhost:4300/mcp -Method Post -ContentType 'application/json' -Body $body
```

`serverInfo.name` 이 `videoTool` 이면 붙은 것이다.

## 자주 나오는 문제

- **502 / 연결 거부** — 서버가 안 떠 있다. `restart.ps1`
- **툴이 안 보인다** — 클라이언트를 다시 시작해야 목록을 다시 읽는다
- **`Unsupported protocol version`** — 클라이언트가 `2024-11-05` 를 보내고 있다. 최신 클라이언트를 쓴다
- **서버를 재시작했더니 끊겼다** — MCP 연결은 세션 시작 때 맺어진다. 클라이언트도 다시 시작한다