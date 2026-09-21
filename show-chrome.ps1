# Flow 조종용 Chrome 창만 화면 안으로 끌어온다 (-Hide 면 다시 화면 밖으로).
#
# launch-chrome.ps1 은 창을 화면 밖(-3000,0)에 띄운다 — 작업 중에 화면을 가리지 않게 하려는 것이다.
# 최소화는 쓰면 안 된다: 최소화된 창은 Chrome 이 그리기를 멈춰 자동 조종이 멈춘다.
# 그래서 "보고 싶을 때" 는 창을 껐다 켜는 게 아니라 **좌표만 옮긴다** — 생성 중이어도 안전하다.
#
# **창은 포트 9222 프로세스의 것만 만진다.** 예전엔 "가장 먼저 뜬 chrome 창" 을 옮겨서
# 사용자가 쓰던 브라우저를 끌어왔다. Chrome 은 프로필마다 프로세스가 따로라 PID 로 갈라야 한다.

param([switch]$Hide)

$port = 9222

$pids = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
  Where-Object { $_.CommandLine -match "remote-debugging-port=$port" -or $_.CommandLine -match "flow_driver" } |
  Select-Object -ExpandProperty ProcessId)

if (-not $pids) {
  Write-Host "포트 $port 로 띄운 Chrome 이 없습니다. .\launch-chrome.ps1 로 먼저 띄우세요."
  exit 1
}

# 같은 프로필의 자식 프로세스(렌더러)도 후보에 넣는다. 창은 보통 부모가 들고 있다.
$pids += @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
  Where-Object { $pids -contains $_.ParentProcessId } | Select-Object -ExpandProperty ProcessId)

if (-not ("Win32.Win" -as [type])) {
  Add-Type -Namespace Win32 -Name Win -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
"@
}

$found = @()
$cb = [Win32.Win+EnumWindowsProc] {
  param($h, $l)
  $wpid = 0
  [void][Win32.Win]::GetWindowThreadProcessId($h, [ref]$wpid)
  if ($pids -contains [int]$wpid) {
    $sb = New-Object System.Text.StringBuilder 512
    [void][Win32.Win]::GetWindowText($h, $sb, $sb.Capacity)
    $title = $sb.ToString()
    if ($title) { $script:found += [pscustomobject]@{ Handle = $h; Title = $title } }
  }
  return $true
}
[void][Win32.Win]::EnumWindows($cb, [IntPtr]::Zero)

# 제목에 Flow 가 들어간 창이 있으면 그것, 없으면 제목 있는 첫 창.
$win = $found | Where-Object { $_.Title -match 'Flow' } | Select-Object -First 1
if (-not $win) { $win = $found | Select-Object -First 1 }

if (-not $win) {
  Write-Host "Flow Chrome 창을 찾지 못했습니다 (PID: $($pids -join ', '))."
  exit 1
}

if ($Hide) {
  [void][Win32.Win]::MoveWindow($win.Handle, -3000, 0, 1920, 1080, $true)
  Write-Host "화면 밖으로 보냈습니다: $($win.Title)"
} else {
  [void][Win32.Win]::ShowWindow($win.Handle, 9)   # SW_RESTORE
  [void][Win32.Win]::MoveWindow($win.Handle, 60, 60, 1280, 960, $true)
  [void][Win32.Win]::SetForegroundWindow($win.Handle)
  Write-Host "화면 안으로 가져왔습니다: $($win.Title)"
}