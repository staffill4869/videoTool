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

$pending = [int]$summary.pending_jobs
Say "대기 $pending 건 / 프로젝트 $($summary.projects)개 / 도는 시리즈 $($summary.active_series)개"

if ($pending -le 0) {
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
videoTool MCP 서버(videocrm 또는 videotool)에 붙어서 대기 중인 일을 처리해.

work_summary 로 남은 일을 확인하고, next_job 을 반복해 불러서 일감이 없을 때까지 처리해.
next_job 이 내주는 일은 넷이다 — 대본 쓰기, 장면 나누기, 허용 수치 쓰기, 나레이션 만들기.
각 일의 instruction 에 적힌 대로 save_script / save_scenes / save_allowed_facts / save_narration 으로 저장해.

make_narration 이 나오면 힉스필드 MCP 로 그 대본의 음성을 만들고,
받은 파일 경로나 URL 을 save_narration(project_id, file) 에 그대로 넘겨라.
길이가 안 맞는다고 낭독 속도를 올리지 마라 — 서버가 무음을 찾아 장면에 맞춰 정렬한다.
저장하면 서버가 합성까지 이어서 한다.

지켜야 할 것
- 대본을 쓰기 전에 estimate_length 로 길이를 확인해. 목표 길이를 넘기면 TTS 가 두 배로 나온다
- 장면은 시리즈의 상시 프롬프트와 주제 브리프를 따라라
- 허용 수치를 반드시 채워라. 없으면 INFO 단계에서 대본에 없는 숫자가 화면에 그려진다
- 낭독 속도를 조절해서 길이를 맞추지 마라. 안 맞으면 대본 글자 수를 고쳐라

하지 말 것
- flow_generate, assemble, publish 를 부르지 마라. 그건 서버가 알아서 한다
- 화면 제어(마우스·키보드)를 쓰지 마라. MCP 도구만 써라
- 사람에게 묻지 마라. 막히면 무엇이 막혔는지 한 줄로 적고 끝내라

다 끝나면 처리한 건수를 한 줄로 보고하고 종료해.
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
