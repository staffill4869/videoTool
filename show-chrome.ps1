# Flow 조종용 Chrome 창을 화면 안으로 끌어온다 (-Hide 면 다시 화면 밖으로).
#
# launch-chrome.ps1 은 창을 화면 밖(-3000,0)에 띄운다 — 작업 중에 화면을 가리지 않게 하려는 것이다.
# 최소화는 쓰면 안 된다: 최소화된 창은 Chrome 이 그리기를 멈춰 자동 조종이 멈춘다.
# 그래서 "보고 싶을 때" 는 창을 껐다 켜는 게 아니라 **좌표만 옮긴다** — 생성 중이어도 안전하다.

param([switch]$Hide)

$port = 9222

$proc = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
  Where-Object { $_.CommandLine -match "remote-debugging-port=$port" } |
  Select-Object -First 1

if (-not $proc) {
  Write-Host "포트 $port 로 띄운 Chrome 이 없습니다. .\launch-chrome.ps1 로 먼저 띄우세요."
  exit 1
}

# 창 손잡이는 같은 프로필의 다른 chrome.exe 프로세스가 들고 있을 수 있다 (렌더러/브라우저 분리).
$handle = (Get-Process -Name chrome | Where-Object { $_.MainWindowHandle -ne 0 } |
  Sort-Object StartTime | Select-Object -First 1).MainWindowHandle

if (-not $handle -or $handle -eq 0) {
  Write-Host "Chrome 창을 찾지 못했습니다."
  exit 1
}

if (-not ("Win32.Move" -as [type])) {
  Add-Type -Namespace Win32 -Name Move -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
"@
}

if ($Hide) {
  [Win32.Move]::MoveWindow($handle, -3000, 0, 1920, 1080, $true) | Out-Null
  Write-Host "Chrome 을 화면 밖으로 보냈습니다. 다시 보려면 .\show-chrome.ps1"
} else {
  [Win32.Move]::ShowWindow($handle, 9) | Out-Null   # SW_RESTORE — 최소화돼 있으면 되돌린다
  [Win32.Move]::MoveWindow($handle, 60, 60, 1280, 960, $true) | Out-Null
  [Win32.Move]::SetForegroundWindow($handle) | Out-Null
  Write-Host "Chrome 을 화면 안으로 가져왔습니다. 숨기려면 .\show-chrome.ps1 -Hide"
}