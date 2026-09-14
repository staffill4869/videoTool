# 무인 제작 루프.
#
# 서버는 프로젝트를 만들고 Flow 단계까지 스스로 민다. 하지만 대본·장면·허용수치는
# 말을 만드는 일이라 서버가 못 한다 — 서버에는 LLM 이 없다.
# 그 세 가지만 채우라고 헤드리스 에이전트를 주기마다 깨운다.
#
# 예약 작업에 등록해서 쓴다:
#   schtasks /create /tn videoTool-agent /tr "powershell -NoProfile -ExecutionPolicy Bypass -File C:\rebase\videoCRM\run-agent.ps1" /sc hourly
#
# 직접 돌려볼 때:
#   .\run-agent.ps1            # 한 번 돌린다
#   .\run-agent.ps1 -DryRun    # 무슨 일이 있는지만 보고 에이전트는 안 깨운다

param(
  [switch]$DryRun,
  [int]$TimeoutSec = 1800
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$api = "http://127.0.0.1:4300"          # localhost 로 쓰면 안 된다 — ::1 로 풀려 연결이 안 된다
$logDir = Join-Path $root "logs"
$lock = Join-Path $root ".agent.lock"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ("agent-" + (Get-Date -Format "yyyy-MM-dd") + ".log")

function Say($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
  Write-Host $line
  # 로그를 못 써도 실행은 계속한다.
  # $ErrorActionPreference = "Stop" 이라 Add-Content 가 한 번 실패하면 스크립트가 통째로
  # 죽는다 — 실제로 로그 파일이 다른 프로세스(tail)에 잠겨 있어 종료 코드 1 로 끝나고
  # 로그도 안 남아 "예약은 돌았는데 아무 일도 안 일어남" 이 됐다. 기록은 부수적인 일이다.
  try {
    Add-Content -Path $log -Value $line -Encoding utf8 -ErrorAction Stop
  } catch {
    # 날짜 파일이 잠겼으면 프로세스별 파일에 남긴다. 그래도 안 되면 화면 출력만으로 충분하다.
    try {
      Add-Content -Path "$log.$PID" -Value $line -Encoding utf8 -ErrorAction Stop
    } catch { }
  }
}

# 앞선 실행이 아직 돌고 있으면 겹쳐 돌리지 않는다.
# 둘이 동시에 next_job 을 집으면 같은 프로젝트에 대본을 두 번 쓴다.
if (Test-Path $lock) {
  $age = (Get-Date) - (Get-Item $lock).LastWriteTime
  if ($age.TotalMinutes -lt 60) {
    Say "이전 실행이 아직 돌고 있습니다 ($([int]$age.TotalMinutes)분째). 건너뜁니다."
    exit 0
  }
  Say "오래된 잠금 파일을 치웁니다 ($([int]$age.TotalMinutes)분)."
  Remove-Item $lock -Force
}

# 서버가 떠 있어야 한다. 없으면 깨울 이유가 없다.
try {
  # 응답이 { ok, summary: {...} } 로 감싸져 있다. MCP 쪽과 모양이 달라 한 겹 벗긴다.
  $summary = (Invoke-RestMethod -Uri "$api/api/work/summary" -TimeoutSec 15).summary
} catch {
  Say "서버에 붙지 못했습니다 ($api). restart.ps1 로 먼저 띄우세요."
  exit 1
}

# Flow 는 Chrome 하나를 물고 돈다. CDP 가 죽으면 그 시점부터 전 단계가 멈추는데
# 조용히 멈춰서 알아채기까지 오래 걸린다 — 하루에 세 번 죽은 적이 있다. 깨어날 때마다 본다.
try {
  Invoke-WebRequest -Uri "http://127.0.0.1:9222/json/version" -TimeoutSec 5 -UseBasicParsing | Out-Null
  Say "Chrome(9222) 정상"
} catch {
  Say "Chrome(9222) 응답 없음 — 다시 띄웁니다"
  Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Where-Object { $_.CommandLine -like '*\.chrome-profile*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 4
  & (Join-Path $root "launch-chrome.ps1")
  Start-Sleep -Seconds 6
}

$pending = [int]$summary.pending_jobs

# pending_jobs 는 **대본 쪽 일만** 센다. 에이전트가 하는 일은 그보다 넓다 —
# CLEAN·INFO·VIDEO·합성·발행이 남아 있어도 pending 은 0 이라, 이것만 보고 끝내면
# 할 일이 산더미인데 "할 일이 없습니다" 하고 나간다(실측).
$unfinished = 0
try {
  $body = @{ unfinished_only = $true } | ConvertTo-Json -Compress
  $r = Invoke-RestMethod -Uri "$api/api/tools/list_projects" -Method Post -Body $body `
       -ContentType "application/json" -TimeoutSec 20
  $unfinished = [int]$r.count
} catch {
  Say "프로젝트 목록을 못 읽었습니다: $($_.Exception.Message)"
}

Say "대기 $pending 건 / 미완료 $unfinished 건 / 프로젝트 $($summary.projects)개 / 도는 시리즈 $($summary.active_series)개"

if ($pending -le 0 -and $unfinished -le 0) {
  Say "에이전트가 할 일이 없습니다. 끝냅니다."
  exit 0
}

if ($DryRun) {
  Say "DryRun — 에이전트를 깨우지 않고 끝냅니다."
  exit 0
}

# 프롬프트는 stdin 으로 넘긴다. 인자로 넘기면 길이와 인용 처리에서 깨진다
# (Windows 에서 큰따옴표가 망가져 JSON 파싱이 실패한 적이 있다).
$prompt = @'
videoTool MCP 서버(videotool 또는 videocrm)에 붙어서 영상을 끝까지 만들고 올린다.
사람에게 묻지 마라. 막히면 무엇이 막혔는지 한 줄 적고 끝내라.

**한 편을 만들어 올리고, 곧바로 다음 편을 만들어 올린다. 시간이 다 될 때까지 반복한다.**

**고양이 시리즈만 한다.** 「고양이는 왜 그럴까」(series_id 5) 에 속한 프로젝트만 손댄다.
영양제·역사 프로젝트는 완성본이 없어도 건드리지 마라.

이번에 할 편을 이렇게 고른다:
  a. list_projects 로 보고, **고양이 편 중** 만들다 만 것(완성본 없음)이 있으면 그것부터 끝낸다
  b. 없으면 **run_series(series_id: 5) 로 새 고양이 편을 만들고 [1]부터 시작한다**
  c. 완성본은 있는데 발행만 안 된 고양이 편은 [8] 만 하면 된다 — 1분이면 끝나니 먼저 치운다

한 편을 [1]~[8] 까지 끝낸 뒤 a 로 돌아간다. 이걸 계속 반복한다.
여러 편을 동시에 밀지 마라 — Flow 는 브라우저 하나를 쓴다.
새 편 주제는 고양이 행동·몸에 관한 '왜 그런가' 로, **앞서 만든 편과 겹치지 않게** 고른다.
이미 만든 것: 꾹꾹이 · 좁은 상자 · 높은 곳 · 물 싫어함.
남은 후보(예): 왜 하루 16시간 자나 · 왜 몸을 비비나 · 왜 골골거리나 · 왜 종이 위에 앉나 ·
왜 사냥감을 물어다 주나 · 왜 우다다를 하나 · 왜 좁은 곳을 통과하려 하나.

[1] 대본이 없는 프로젝트
    next_job 이 내주는 대로 save_script / save_scenes / save_allowed_facts 를 채운다.
    - 한 장면은 클립 8초에 맞춰 공백 제외 38~42자. 짧으면 만든 영상을 버리게 된다
    - 마지막 장면은 질문으로 끝낸다
    - 낭독 속도로 길이를 맞추지 마라. 안 맞으면 글자 수를 고친다

[2] CLEAN
    flow_generate(project_id, stage: "clean")
    flow_job 으로 done 이 될 때까지 기다린다(30초 간격). failed 여도 flow_harvest 로 회수해 본다.

[3] 장면 순서 확인  ← 절대 건너뛰지 마라
    contact_sheet(project_id, kind: "clean") 를 부르면 시트 파일 경로와
    칸마다 어느 장면 대사인지가 나온다. 그 파일을 Read 로 **직접 열어 보고**,
    칸의 그림이 그 장면 대사와 맞는지 하나씩 확인한다.
    어긋나면 remap_scenes(kind: "clean", order: [...]) 로 고친다.
    order 는 "1번 장면에 지금 몇 번 칸 그림을 쓸지" 의 나열이다. 예: [5,1,4,2,7,8,6,3]
    배정 신뢰도가 높아도 순서는 뒤섞여 있다. 실제로 만든 편마다 전부 고쳐야 했다.

[4] INFO
    flow_generate(stage: "info") → 기다림 →
    contact_sheet(kind: "info") 로 다시 확인한다. INFO 는 라벨이 붙어 있어 판단이 쉽다.
    어긋나면 clean 과 info 를 **같은 order 로 함께** remap 한다. 둘은 짝이다.

[5] VIDEO
    flow_generate(stage: "video") → 기다림 → flow_harvest(stage: "video")
    장면이 다 안 차면 flow_generate(stage: "video") 를 다시 부른다.
    (없는 장면만 자동으로 요청한다. 3~4라운드가 걸릴 수 있다)
    90% 이상 차면 다음으로 간다.

[6] 음성
    각 장면 대사를 힉스필드로 만든다:
      generate_audio_batch(model "text2speech_v2", variant "elevenlabs",
                           voice_type "preset", voice_id <프로젝트 보이스>)
    한 번에 12개를 보내면 429 로 일부가 거부된다. submission_failed 는 다시 보낸다.
    jobs_wait 로 끝나면 결과 URL 을 받아 projects/<id>/work/tts/sNN.mp3 로 내려받는다.

[7] 합성
      powershell -File .inish-video.ps1 -ProjectId <id>
    나레이션 정렬·자막·합성을 한 번에 한다.

[8] 발행
    save_publish_meta(project_id, channel_slug, title, description, hashtags) 로 메타를 넣고
    publish(project_id, channel_slug, confirm: true) 로 올린다.
    channel_slug 는 그 프로젝트가 속한 시리즈의 channel_slug 를 쓴다.
    공개 범위는 손대지 마라 — 채널 설정이 private 이면 서버가 무조건 private 으로 올린다.
    제목은 영상 내용 그대로, 낚시 금지. 설명 끝에 마지막 장면의 질문을 넣는다.

지켜야 할 것
- [3] 과 [4] 의 시트 확인을 건너뛰지 마라. 이걸 빼면 대사와 화면이 끝까지 어긋난다
- 한 번에 한 편만. 다른 편으로 넘어가기 전에 그 편을 끝낸다
- 화면 제어(마우스·키보드)를 쓰지 마라. MCP 도구와 위에 적힌 명령만 쓴다
- 크레딧이 나가는 일이다. 같은 단계를 이유 없이 두 번 돌리지 마라

시간이 얼마 안 남았으면 새 편을 시작하지 말고, 만든 편과 올린 주소를 한 줄로 보고하고 종료해.
'@

New-Item -ItemType File -Path $lock -Force | Out-Null
Say "에이전트를 깨웁니다 (최대 $TimeoutSec 초)"

try {
  $out = Join-Path $logDir ("run-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")

  # --print: 대화창 없이 한 번 돌고 끝난다.
  $p = Start-Process -FilePath "claude" `
    -ArgumentList "--print", "--permission-mode", "acceptEdits" `
    -WorkingDirectory $root `
    -RedirectStandardInput (New-TemporaryFile | ForEach-Object { $prompt | Set-Content $_ -Encoding utf8; $_ }) `
    -RedirectStandardOutput $out `
    -RedirectStandardError "$out.err" `
    -NoNewWindow -PassThru

  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    Say "시간 초과 — 에이전트를 종료합니다"
    $p.Kill()
  } else {
    Say "에이전트 종료 (코드 $($p.ExitCode))"
  }

  $tail = Get-Content $out -Tail 5 -ErrorAction SilentlyContinue
  if ($tail) { $tail | ForEach-Object { Say "  > $_" } }
} finally {
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
}

# 처리 뒤 남은 일을 다시 본다. 줄지 않았으면 뭔가 막힌 것이다.
try {
  $after = (Invoke-RestMethod -Uri "$api/api/work/summary" -TimeoutSec 15).summary
  Say "끝난 뒤 대기 $($after.pending_jobs)건 (시작 $pending 건)"
  if ([int]$after.pending_jobs -ge $pending) {
    Say "줄지 않았습니다. $out 을 확인하세요."
  }
} catch {
  Say "종료 후 상태 조회 실패"
}
