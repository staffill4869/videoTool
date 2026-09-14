
## 2026-09-14 12:40
- **[videoTool/발행]** 완성본이 다 있는 편 7개가 `publish` 에서 "최종 검증(final)이 통과되지 않았습니다" 로 전부 막혔다 → `Validation.run(project, "final")` 을 부르는 곳이 **LiveView 의 '검증' 버튼 하나뿐**이었다(`ingest` 는 clean·info·clips 만 돈다). `assemble` 도 `next` 도 final 을 기록하지 않는다 → 무인 에이전트는 화면을 못 누르므로 **영원히 발행 불가**였다. MCP/REST 에 `validate(project_id, stage)` 를 추가해 뚫었다. **규칙: 사람이 눌러야만 지나갈 수 있는 관문을 자동 경로 한가운데 두지 마라 — UI 전용 부작용은 반드시 도구로도 노출한다**
- **[videoTool/발행]** `assemble` 을 다시 돌리면 `renders` 행이 새로 생겨 기존 발행 초안이 옛 render 를 물고 있게 되고 `publish` 가 "발행 초안이 없습니다" 로 거절한다 → **assemble 뒤에는 `save_publish_meta` 를 다시 부른다.** 순서는 assemble → validate(final) → save_publish_meta → publish
- **[Phoenix/dev]** `mix phx.server` 로 떠 있는 서버는 code reloader 가 요청마다 재컴파일하므로, `lib/` 에 MCP 도구를 추가하고 **재시작 없이** 첫 REST 호출에서 바로 붙었다 → dev 서버에 도구를 급히 추가할 때 restart.ps1 을 돌릴 필요가 없다(재시작하면 Flow CDP 연결과 running 작업 정리가 딸려 온다)
- **[MCP/인자]** `save_publish_meta` 의 `hashtags` 는 배열인데 문자열로 넘기면 `1st argument: not a list` 로 죽는다. 한글이 든 긴 JSON 은 bash 인용에서 깨지므로 **파일에 써서 `curl --data-binary @파일`** 로 넘긴다
