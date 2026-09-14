# 새 PC에 설치하기

이 문서는 **videoTool 을 처음 보는 사람이 그대로 따라 할 수 있게** 쓴 것이다.
Windows 기준. 다 끝나면 그 PC 혼자서 영상을 만들고 유튜브에 올린다.

왜 PC 를 옮기는가: **유튜브 업로드 토큰은 채널을 소유한 구글 계정에서만 받을 수 있다.**
남의 채널에 스튜디오 권한(관리자·편집자)으로 초대받아도 API 로는 못 올린다 —
`videos.insert` 에 채널을 지정하는 항목이 없어서 토큰이 가리키는 채널로만 올라가기 때문이다.
그래서 채널 소유자 계정이 있는 PC 에서 돌리는 게 가장 간단하다.

---

## 0. 준비물

| | 확인 명령 | 비고 |
|---|---|---|
| Elixir / Erlang | `mix --version` | scoop 이나 공식 설치본 |
| PostgreSQL | `psql --version` | 로컬에 띄워 둔다 |
| ffmpeg · ffprobe | `ffmpeg -version` | `scoop install ffmpeg` |
| Node.js | `node -v` | Flow 조종 스크립트용 |
| Google Chrome | | Flow 를 띄울 브라우저 |
| Claude Code | `claude --version` | 무인 루프가 이걸 부른다 |

**구글 쪽도 미리 준비한다** (채널 소유 계정으로):

1. https://console.cloud.google.com 에서 프로젝트 생성
2. API 및 서비스 → 라이브러리 → **YouTube Data API v3** → 사용 설정
3. 사용자 인증 정보 → **API 키** 생성 (성과 수집용)
4. 사용자 인증 정보 → **OAuth 클라이언트 ID** → 웹 애플리케이션
   - 승인된 리디렉션 URI: `http://localhost:4300/oauth/google/callback`
5. OAuth 동의 화면 → **"프로덕션" 으로 게시**
   - "테스트" 로 두면 **refresh token 이 7일마다 만료된다.** 무인 루프가 일주일 뒤 멈춘다

---

## 1. 코드 받기

```powershell
git clone https://github.com/staffill4869/videoTool.git C:\videoTool
cd C:\videoTool
```

**저장소에 없는 것** (있어야 도는 것들):

| | 어떻게 구하나 |
|---|---|
| `.env` | `.env.example` 을 복사해 값을 채운다 (아래 2번) |
| `.credentials/` | 이 PC 에서 유튜브 로그인하면 생긴다. **복사해 와도 안 된다** — DPAPI 로 암호화돼 있어 같은 PC·같은 사용자만 푼다 |
| `.chrome-profile/` | 이 PC 에서 Flow 에 구글 로그인하면 생긴다 |
| `projects/` | 만들면서 쌓인다. 예전 영상을 옮기려면 폴더째 복사 + DB 도 함께 옮겨야 한다 |

## 2. `.env` 채우기

```powershell
Copy-Item .env.example .env
notepad .env
```

```
GOOGLE_API_KEY=...        # 1단계 3번에서 만든 키
GOOGLE_CLIENT_ID=...      # 1단계 4번
GOOGLE_CLIENT_SECRET=...
DATABASE_URL=...          # 예: ecto://postgres:postgres@localhost/video_tool_dev
```

## 3. DB 와 프롬프트

```powershell
mix setup                              # deps · DB 생성 · 마이그레이션 · 시드
mix run priv/repo/sync_prompts.exs     # priv/prompts/*.txt → DB
mix run priv/repo/voice_previews.exs   # 목소리 미리듣기 주소
```

## 4. 서버 띄우기

```powershell
.\restart.ps1
```

`http://localhost:4300` 이 열리면 된다. 포트 4300 리스너 PID 만 죽이고 다시 띄우는
스크립트라 **다른 프로젝트 서버를 건드리지 않는다.**

## 5. Flow 용 Chrome

```powershell
.\launch-chrome.ps1
```

디버그 포트 9222 로 전용 프로필 Chrome 이 뜬다. **그 창에서 직접 구글 로그인하고
Flow(https://flow.google.com) 에 들어가 둔다.** 자동화는 로그인을 대신하지 않는다.

> 이 창을 닫거나 Chrome 이 죽으면 그 시점부터 영상 생성이 전부 멈춘다.
> 무인 루프가 깨어날 때마다 확인하고 죽었으면 다시 띄운다.

## 6. 유튜브 채널 연결

화면 `/channels` 에서 하거나, MCP 로:

```
login_channel(channel_slug: "yt-supplement")
```

브라우저가 뜨면 **채널을 소유한 계정**으로 로그인 → 계속 → 허용.
끝나면 어느 채널에 붙었는지 자동으로 기록된다. `/channels` 에서 확인한다.

계정이 채널을 여러 개 **소유**하면 중간에 채널 선택 화면이 나온다. 거기서 고른 채널로 올라간다.
위임받은(관리자·편집자) 채널은 이 목록에 나오지 않는다 — 위 머리말 참고.

시리즈마다 다른 채널에 올리려면 `channels` 행을 나누고 **행마다 따로 로그인**한다.
`credential_ref` 가 같으면 같은 채널이 된다.

```powershell
mix run priv/repo/seed_channels.exs    # 시리즈별 채널 행 + 시리즈↔채널 연결
```

## 7. 무인 루프 켜기

`.claude/settings.local.json` 의 `permissions.allow` 가 이미 들어 있다.
비대화형에서는 승인창을 띄울 수 없어서, 목록에 없는 도구는 그냥 거부된다.

```powershell
# 한 번 돌려보기 (에이전트는 안 깨우고 상황만 본다)
.\run-agent.ps1 -DryRun

# 실제로 한 번
.\run-agent.ps1
```

주기 실행 등록:

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\videoTool\run-agent.ps1 -TimeoutSec 2700" `
  -WorkingDirectory "C:\videoTool"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
  -RepetitionInterval (New-TimeSpan -Minutes 30)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 55) `
  -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "videoTool-agent" -Action $action `
  -Trigger $trigger -Settings $settings -Force
```

## 8. 계속 돌게 만들기 (상시 가동 PC)

기본 설정으로는 **로그오프하거나 절전에 들어가면 멈춘다.** 셋 다 해야 한다.

1. **로그온 여부와 무관하게 실행** — 예약 작업 속성 → 보안 옵션
   → "사용자의 로그온 여부에 관계없이 실행" (계정 비밀번호를 한 번 묻는다)
2. **절전 끄기**
   ```powershell
   powercfg /change standby-timeout-ac 0
   powercfg /change hibernate-timeout-ac 0
   powercfg /change monitor-timeout-ac 10
   ```
3. **부팅 시 서버·Chrome 자동 시작** — 시작 트리거 예약 작업 2개를 더 만든다
   (`restart.ps1`, `launch-chrome.ps1`)

## 9. 잘 도는지 보기

브라우저에서 **`http://localhost:4300/agent`**.

- 지금 돌고 있나 / 예약 상태 / Chrome 연결을 신호등으로 보여준다
- 프로젝트마다 단계(장면·CLEAN·INFO·VIDEO·완성)와 "지금 무엇을 기다리는지" 한 줄
- 맨 아래 최근 루프 기록

다른 PC 나 폰에서 보려면 이 주소를 LAN 이나 터널로 열면 된다.

---

## 이 PC 에서만 겪는 함정

**PowerShell 7 이 깔려 있으면 토큰 저장이 실패한다.**
`PSModulePath` 앞쪽에 PS7 경로가 끼어들어 Windows PowerShell 5.1 이 호환되지 않는
`Microsoft.PowerShell.Security` 를 집는다. 코드에서 5.1 기본 경로로 되돌려 두었지만,
비슷한 증상이 보이면 이 자리를 의심한다.

**`mix run` 은 앱을 부팅한다.** 예전에는 그때 "끊긴 Flow 작업 청소" 가 돌아서
서버에서 **멀쩡히 돌고 있던** 작업까지 실패로 찍었다. 지금은 웹을 실제로 띄울 때만 돈다.

**같은 Flow 계정을 두 PC 에서 동시에 돌리지 마라.** 브라우저를 서로 뺏는다.
생성은 한 기계에서만 하고, 나머지는 화면만 본다.

**장면 순서는 자동으로 안 맞는다.** CLEAN 이 나오면 `contact_sheet` 로 한 장에 늘어놓고
눈으로 본 뒤 `remap_scenes` 로 고쳐야 한다. 배정 신뢰도가 높아도 순서는 뒤섞여 있다.
무인 루프도 이 단계를 거치게 되어 있다 — 건너뛰면 대사와 화면이 끝까지 어긋난다.

나머지 함정은 `README.md` 와 `CLAUDE.md` 에 있다.
