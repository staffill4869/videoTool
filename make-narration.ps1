# 장면별 나레이션을 만들어 영상에 정확히 맞춘다.
#
# 왜 장면별인가: 통짜 TTS 하나를 클립 묶음에 얹으면 원리상 안 맞는다.
# 영상은 클립 누적(0-8, 8-16, 16-24...)으로 가는데 통짜 나레이션은 글자 수 비례로
# 나뉘어 네 번째 장면에서 9초까지 벌어졌다. 장면마다 따로 만들어 각자 클립 길이에
# 맞춰 무음을 채우면 총 길이가 영상과 정확히 같아진다.
#
#   .\make-narration.ps1 -ProjectId 21 -LinesFile lines21.json
#   .\make-narration.ps1 -ProjectId 21 -LinesFile lines21.json -Voice "Microsoft Heami Desktop"
#
# LinesFile 은 {"1":"장면1 대사","2":"장면2 대사",...} 형태. 키는 scene_no.

param(
  [Parameter(Mandatory = $true)][int]$ProjectId,
  [Parameter(Mandatory = $true)][string]$LinesFile,
  [string]$Voice = "Microsoft Heami Desktop",
  [int]$Rate = 0,
  [string]$Api = "http://127.0.0.1:4300"   # localhost 로 쓰면 ::1 로 풀려 연결이 안 된다
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj = Join-Path $root "projects\$ProjectId"
$tts  = Join-Path $proj "work\tts"

function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

if (-not (Test-Path $LinesFile)) { throw "대사 파일이 없습니다: $LinesFile" }
New-Item -ItemType Directory -Force -Path $tts | Out-Null

# 1. 장면별 클립 길이를 서버에서 받는다. 이게 각 장면의 슬롯 길이다.
$env:PGPASSWORD = "postgres"
$rows = & psql -U postgres -h localhost -d video_tool_dev -A -t -F "|" -c @"
select s.scene_no, coalesce(a.duration_sec, 0)
from scenes s
left join assets a on a.scene_id = s.id and a.kind = 'clip'
where s.project_id = $ProjectId
order by s.scene_no
"@

$slot = @{}
foreach ($r in $rows) {
  if ($r -match '^\s*(\d+)\|([\d.]+)\s*$') { $slot[$matches[1]] = [double]$matches[2] }
}
if ($slot.Count -eq 0) { throw "장면을 찾지 못했습니다 (프로젝트 $ProjectId)" }

# 2. 장면마다 음성을 만든다.
$lines = Get-Content $LinesFile -Raw -Encoding utf8 | ConvertFrom-Json
Add-Type -AssemblyName System.Speech
$sp = New-Object System.Speech.Synthesis.SpeechSynthesizer
$sp.SelectVoice($Voice)
$sp.Rate = $Rate

Get-ChildItem $tts -Filter *.wav -ErrorAction SilentlyContinue | Remove-Item -Force
$made = @()

foreach ($p in $lines.PSObject.Properties) {
  $no = $p.Name
  if (-not $slot.ContainsKey($no) -or $slot[$no] -le 0) {
    Say "장면 $no — 클립이 없어 건너뜁니다"
    continue
  }
  $raw = Join-Path $tts ("s{0}.wav" -f $no.PadLeft(2, '0'))
  $sp.SetOutputToWaveFile($raw)
  $sp.Speak($p.Value)
  $made += [pscustomobject]@{ No = $no; Raw = $raw; Slot = $slot[$no] }
}
$sp.SetOutputToNull(); $sp.Dispose()
Say "음성 $($made.Count) 개 생성"

# 3. 각 음성을 그 장면의 클립 길이에 정확히 맞춘다.
#    짧으면 무음을 채우고, 길면 잘린다 — 길면 대사를 줄여야 한다는 신호다.
$listFile = Join-Path $tts "list.txt"
Remove-Item $listFile -ErrorAction SilentlyContinue
$over = @()

foreach ($m in ($made | Sort-Object { [int]$_.No })) {
  $dur = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 $m.Raw)
  if ($dur -gt $m.Slot) { $over += "장면 $($m.No): 음성 $([math]::Round($dur,1))초 > 슬롯 $($m.Slot)초" }

  $padded = Join-Path $tts ("p{0}.wav" -f $m.No.PadLeft(2, '0'))
  & ffmpeg -v error -y -i $m.Raw -af apad -t $m.Slot -ar 44100 -ac 2 $padded
  # ffmpeg concat 목록에 BOM 이 붙으면 첫 줄이 "unknown keyword '﻿file'" 로 죽는다.
  # PowerShell 5.1 의 -Encoding utf8 은 BOM 을 붙인다. 파일명은 ASCII 라 ascii 로 쓴다.
  Add-Content -Path $listFile -Value ("file '{0}'" -f (Split-Path $padded -Leaf)) -Encoding ascii
}

if ($over.Count -gt 0) {
  Say "!! 슬롯을 넘는 장면이 있습니다 — 대사를 줄이세요 (속도를 올리지 말 것)"
  $over | ForEach-Object { Say "   $_" }
}

# 4. 이어 붙인다. 총 길이가 클립 합계와 같아야 정상이다.
$out = Join-Path $proj "narration_aligned.wav"
Push-Location $tts
try { & ffmpeg -v error -y -f concat -safe 0 -i "list.txt" -c copy $out } finally { Pop-Location }

$total = [double](& ffprobe -v error -show_entries format=duration -of csv=p=0 $out)
$want  = ($made | Measure-Object -Property Slot -Sum).Sum
Say ("나레이션 {0:N1}초 / 클립 합계 {1:N1}초" -f $total, $want)

# 5. 서버에 등록한다. scene_timing 은 서버가 클립 길이에서 다시 뽑는다.
$body = @{ project_id = $ProjectId; file = ($out -replace '\\', '/') } | ConvertTo-Json -Compress
$res = Invoke-RestMethod -Uri "$Api/api/tools/save_narration" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 180
Say "등록 완료 — 장면 $($res.scenes)개 / 자막 $($res.subtitles)줄 / $([math]::Round($res.duration_sec,1))초"
