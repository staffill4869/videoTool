# 클립이 다 나온 프로젝트를 완성본까지 끝낸다.
#
# 개별 영상은 나왔는데 풀영상이 없는 프로젝트를 찾아, 장면별 음성을 클립 길이에 맞춰
# 이어 붙이고 합성한다. 음성 파일은 **미리 work/tts/sNN.wav 로 넣어둬야 한다** —
# 서버에는 TTS 키가 없고, 힉스필드 MCP 는 에이전트만 부를 수 있다.
#
#   .\finish-video.ps1                 # 끝낼 수 있는 프로젝트 목록만 보여준다
#   .\finish-video.ps1 -ProjectId 17   # 그 프로젝트를 완성본까지 만든다
#   .\finish-video.ps1 -All            # 끝낼 수 있는 것을 전부 만든다
#
# 왜 장면별인가: 통짜 나레이션 하나를 클립 묶음에 얹으면 원리상 안 맞는다.
# 영상은 클립 누적(0-8, 8-16 ...)으로 가는데 통짜는 글자 수 비례로 나뉘어
# 네 번째 장면에서 9초까지 벌어졌다.
#
# 무음은 채우지 않는다. 예전에는 장면 음성을 클립 길이까지 늘려 맞췄는데,
# 5초 대사에 8초 클립이면 3초가 빈 소리로 남아 장면마다 말이 끊겼다.
# 지금은 음성을 그대로 두고 **화면 쪽을 그 길이로 자른다** (save_narration 의 scene_secs).
# 마지막 장면만 클립을 통째로 쓴다 — 끝맺음 여운은 있어야 한다.
#
# 대사 뒤에는 -Gap 초(기본 0.3)만큼 숨 쉴 틈을 남긴다. 0 으로 붙이면 다음 장면 대사가
# 바로 시작돼 딱딱 끊기는 느낌이 난다. 그 틈 동안 화면은 라벨이 다 얹힌 마지막 프레임에 머문다.

param(
  [int]$ProjectId = 0,
  [switch]$All,
  # 장면마다 대사 뒤에 남길 숨 쉴 틈(초). 0 이면 대사가 끝나자마자 다음 장면 대사가
  # 바로 붙어 딱딱 끊기는 느낌이 난다. 이 시간 동안 화면은 그 장면의 마지막
  # (라벨이 다 얹힌 INFO) 프레임에 머문다.
  [double]$Gap = 0.3,
  [string]$Api = "http://127.0.0.1:4300"   # localhost 로 쓰면 ::1 로 풀려 연결이 안 된다
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:PGPASSWORD = "postgres"

function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

function Get-Rows($sql) {
  $out = & psql -U postgres -h localhost -d video_tool_dev -A -t -F "|" -c $sql
  # ,  가 없으면 파이프라인이 배열을 펼쳐 버려 행이 아니라 낱개 문자열이 나온다.
  return @($out | Where-Object { $_ -match '\|' } | ForEach-Object { , $_.Split('|') })
}

# 끝낼 수 있는 것 = 클립이 장면의 90% 이상인데 완성본이 없는 프로젝트.
# 90% 는 assemble 이 거부하는 경계와 같다 — 더 낮으면 토막 영상이 나온다.
function Get-Candidates {
  Get-Rows @"
select p.id,
       (select count(*) from scenes s where s.project_id=p.id),
       (select count(distinct a.scene_id) from assets a
          where a.project_id=p.id and a.kind='clip' and a.scene_id is not null),
       (select count(*) from renders r where r.project_id=p.id),
       replace(p.title,'|','/')
from projects p
where (select count(*) from scenes s where s.project_id=p.id) > 0
order by p.id
"@ | Where-Object {
    $scenes = [int]$_[1]; $clips = [int]$_[2]; $renders = [int]$_[3]
    $renders -eq 0 -and $scenes -gt 0 -and $clips -ge [math]::Ceiling($scenes * 0.9)
  }
}

function Complete-Project([int]$id) {
  $proj = Join-Path $root "projects\$id"
  $tts  = Join-Path $proj "work\tts"

  # 1. 장면별 클립 길이 = 그 장면 화면의 최대치. 겹친 클립은 가장 긴 것을 쓴다.
  $slot = @{}
  foreach ($r in Get-Rows @"
select s.scene_no, coalesce(max(a.duration_sec), 0)
from scenes s
left join assets a on a.scene_id = s.id and a.kind = 'clip'
where s.project_id = $id
group by s.scene_no order by s.scene_no
"@) {
    if ([double]$r[1] -gt 0) { $slot[$r[0].Trim()] = [double]$r[1] }
  }
  if ($slot.Count -eq 0) { throw "프로젝트 $id — 클립이 붙은 장면이 없습니다" }

  $order = @($slot.Keys | Sort-Object { [int]$_ })
  $lastNo = $order[-1]

  # 2. 음성 파일이 있어야 한다. 없으면 무엇을 만들어야 하는지 알려주고 멈춘다.
  function Find-Audio($no) {
    foreach ($ext in @("mp3", "wav")) {
      $f = Join-Path $tts ("s{0}.{1}" -f $no.PadLeft(2, '0'), $ext)
      if (Test-Path $f) { return $f }
    }
    return $null
  }

  $missing = @($order | Where-Object { -not (Find-Audio $_) })
  if ($missing.Count -gt 0) {
    Say "프로젝트 $id — 음성이 없습니다. 아래 장면의 대사를 TTS 로 만들어 $tts 에 넣으세요:"
    foreach ($no in $missing) {
      $line = (Get-Rows @"
select sg.text from script_segments sg
join scenes s on s.id = sg.scene_id
join scripts sc on sc.id = sg.script_id and sc.is_active
where s.project_id = $id and s.scene_no = $no
"@ | Select-Object -First 1)
      $text = if ($line) { $line[0] } else { "(대본 없음)" }
      Say ("   s{0}.mp3  ({1:N1}초 이내)  {2}" -f $no.PadLeft(2, '0'), $slot[$no], $text)
    }
    return $false
  }

  # 3. 무음을 채우지 않는다.
  #
  #    예전에는 장면마다 음성을 클립 길이(8초)까지 apad 로 늘렸다. 5초짜리 대사면
  #    3초가 통째로 빈 소리로 남아 장면마다 말이 끊겼다. 이제는 음성을 그대로 두고,
  #    **화면 쪽을 그 길이에 맞춰 자른다** (서버의 scene_secs 가 그 일을 한다).
  #    마지막 장면만 클립을 통째로 쓰므로 여기서만 뒤를 무음으로 채운다.
  $listFile = Join-Path $tts "list.txt"
  Remove-Item $listFile -ErrorAction SilentlyContinue
  Get-ChildItem $tts -Filter "p*.wav" -ErrorAction SilentlyContinue | Remove-Item -Force
  $secs = @{}
  $over = @()

  foreach ($no in $order) {
    $pad = $no.PadLeft(2, '0')
    $raw = Find-Audio $no
    $out = Join-Path $tts "p$pad.wav"

    if ($no -eq $lastNo) {
      # 끝 장면: 클립을 다 보여주고 남는 뒤는 무음. apad 는 -t 와 짝이다.
      & ffmpeg -v error -y -i $raw -af apad -t $slot[$no] -ar 44100 -ac 2 $out
    } else {
      # 대사 + 숨 쉴 틈.
      #
      # **대사는 절대 자르지 않는다.** 예전엔 클립 길이(8초)에서 끊었는데,
      # 8.64초짜리 대사가 8.00초로 잘려 첫 문장 끝이 날아갔다 — 앞이 끊기게 들린다.
      # 넘치면 자르는 게 아니라 화면을 그만큼 늦춘다 (서버가 1.35배까지 배속으로 맞춘다).
      # 그 한계를 넘으면 마지막 프레임이 멈추므로 거기서만 끊는다.
      $rd = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 $raw)
      $stop = [math]::Min([math]::Round($rd + $Gap, 3), $slot[$no] * 1.35)
      & ffmpeg -v error -y -i $raw -af apad -t $stop -ar 44100 -ac 2 $out
    }

    $d = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 $out)
    $secs[$no] = [math]::Round($d, 3)
    # 음성이 클립보다 훨씬 길면 화면이 느려지거나 마지막 프레임이 멈춘다 — 대사를 줄일 신호.
    if ($d -ge $slot[$no] * 1.35) { $over += ("장면 {0}: 음성 {1:N1}초 > 클립 {2:N1}초 x1.35 — 대사가 잘렸습니다" -f $no, $d, $slot[$no]) }

    # ffmpeg concat 목록에 BOM 이 붙으면 첫 줄이 unknown keyword 로 죽는다.
    Add-Content -Path $listFile -Value "file 'p$pad.wav'" -Encoding ascii
  }

  if ($over.Count -gt 0) {
    Say "!! 클립보다 많이 긴 장면이 있습니다 — 대사를 줄이세요 (낭독 속도를 올리지 말 것)"
    $over | ForEach-Object { Say "   $_" }
  }

  # 4. 이어 붙인다. 무음이 없으니 총 길이는 실제 말한 시간의 합이다.
  $out = Join-Path $proj "narration_aligned.wav"
  Push-Location $tts
  try { & ffmpeg -v error -y -f concat -safe 0 -i "list.txt" -c copy $out } finally { Pop-Location }

  $total = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 $out)
  Say ("프로젝트 $id — 나레이션 {0:N1}초 (클립 원본 합계 {1:N1}초)" -f $total, ($slot.Values | Measure-Object -Sum).Sum)

  # 5. 등록하고 합성한다. scene_secs 를 주면 서버가 장면마다 클립 뒤를 잘라
  #    화면과 말이 딱 붙는다. 마지막 장면만 통째로 남는다.
  $body = @{ project_id = $id; file = ($out -replace '\\', '/'); scene_secs = $secs } | ConvertTo-Json -Compress
  $n = Invoke-RestMethod -Uri "$Api/api/tools/save_narration" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 180
  Say ("   나레이션 등록 — 장면 {0}개 / 자막 {1}줄" -f $n.scenes, $n.subtitles)

  $a = Invoke-RestMethod -Uri "$Api/api/tools/assemble" -Method Post -Body (@{ project_id = $id } | ConvertTo-Json -Compress) -ContentType "application/json" -TimeoutSec 600
  if ($a.ok) {
    Say ("   완성 — {0:N1}초 / 클립 {1}개 / {2}" -f $a.duration_sec, $a.clips, $a.file_path)
    Say ("   재생: $Api/renders/$($a.render_id)/play")
    return $true
  }
  Say "   합성 실패: $($a.error)"
  return $false
}

# ── 실행 ────────────────────────────────────────────────────────────
$cands = Get-Candidates

if ($ProjectId -eq 0 -and -not $All) {
  if ($cands.Count -eq 0) { Say "완성본이 없는데 클립이 다 찬 프로젝트가 없습니다."; exit 0 }
  Say "완성본으로 만들 수 있는 프로젝트:"
  foreach ($c in $cands) { Say ("   #{0}  장면 {1} / 클립 {2}  {3}" -f $c[0], $c[1], $c[2], $c[4]) }
  Say "만들려면: .\finish-video.ps1 -ProjectId <번호>   또는   -All"
  exit 0
}

$targets = if ($All) { $cands | ForEach-Object { [int]$_[0] } } else { @($ProjectId) }
$done = 0
foreach ($t in $targets) {
  try { if (Complete-Project $t) { $done++ } }
  catch {
    Say "프로젝트 $t — 실패: $($_.Exception.Message)"
    Say ("   " + ($_.ScriptStackTrace -split "`n" | Select-Object -First 3) -join " | ")
  }
}
Say "끝났습니다. 완성 $done / 대상 $($targets.Count)"
