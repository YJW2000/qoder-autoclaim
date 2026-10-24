<#
Qoder自动签到脚本 (Qoder AutoClaim) - Qoder 每日积分自动领取
适配 Qoder 0.4.11+ (旧版 0.4.x 同样可用)
规则: 每日 10:00 (UTC+8) 刷新后, 桌面端左下角「打开用户菜单」->「权益中心，有权益待领取」
     -> 「权益活动内容 / 专属活动权益」弹层 -> 点击「领取」。
     领取成功的证据: 弹层内按钮变为「已领取」，或出现「领取成功，Credits 已到账」。
     注意: 「我的用量」面板里没有领取入口, 不要在用量面板里找。

用法:
  powershell -NoProfile -ExecutionPolicy Bypass -File Qoder-AutoClaim.ps1 -DumpTree
      恢复并扫描 Qoder 窗口, 导出全部可交互控件到 %LOCALAPPDATA%\QoderAutoClaim\uia-latest.txt
  powershell -NoProfile -ExecutionPolicy Bypass -File Qoder-AutoClaim.ps1 -DryRun
      只检测并报告当前状态, 不点击任何控件(弹层未打开时也不会打开)
  powershell -NoProfile -ExecutionPolicy Bypass -File Qoder-AutoClaim.ps1
      正式领取
  powershell -NoProfile -ExecutionPolicy Bypass -File Qoder-AutoClaim.ps1 -ExePath "C:\...\Qoder.exe"
      正式领取(可选 -ExePath 指定 Qoder.exe)
退出码: 0=成功/已领取/暂无领取入口(待下轮重试)  2=未到领取时间且超等待上限
        3=入口或弹层流程未走通/结果未知(未写标记)  4=环境异常

关键改动 (2026-10-24, 适配 Qoder 0.4.11):
  - 不再用 Get-Process.MainWindowHandle 猜主进程: 新版 Qoder 有多个同名进程,
    MainWindowHandle 可能落在 helper 上, 导致明明 Qoder 在前台却判定"未能调到前台"。
    现在用 EnumWindows 枚举可见顶层窗口, 选标题为 Qoder、面积最大的主窗口。
  - 前台/点击安全校验改为按进程名 Qoder 判断(接受全部 Qoder 进程), 不再要求 PID 完全相等。
  - 菜单项只接受可见的 MenuItem(或小尺寸 Button), 不再用大段聊天文本匹配「权益中心」。
  - 兼容旧弹层名「权益活动内容」和新标题「专属活动权益」。
#>
param(
    [switch]$DryRun,
    [switch]$DumpTree,
    [int]$MaxWaitMinutes = 50,
    [string]$ExePath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace Native {
public static class Win32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
}
'@
[void][Native.Win32]::SetProcessDPIAware()

# ==================== 配置 ====================
$QoderProcessName  = 'Qoder'
$ClaimHour         = 10
$ClaimMinute       = 5
$RefreshHour       = 10
$RefreshMinute     = 0
$MenuButtonRegex   = '^打开用户菜单$'
$RightsEntryRegex  = '权益中心'
$RightsDialogRegex = '权益活动内容|专属活动权益'
$ClaimRegex        = '^领取$'
$ClaimedRegex      = '已领取|领取成功|Credits 已到账|Claimed|明日再来|明天再来|今日已领'

$Root       = Join-Path $env:LOCALAPPDATA 'QoderAutoClaim'
$LogFile    = Join-Path $Root 'autoclaim.log'
$MarkerFile = Join-Path $Root 'last-claim.txt'
$DumpFile   = Join-Path $Root 'uia-latest.txt'
$ShotFile   = Join-Path $Root 'screen-latest.png'
$ExeCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Qoder\Qoder.exe'),
    (Join-Path $env:ProgramFiles 'Qoder\Qoder.exe')
)
if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
$script:LogEncoding = New-Object System.Text.UTF8Encoding($false)
$script:PidCache = @{}

# ==================== 日志与诊断 ====================
function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", $script:LogEncoding) } catch { }
    Write-Host $line
}

function Save-Screenshot {
    try {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
        $g.Dispose()
        $bmp.Save($ShotFile, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Log INFO "已保存截图: $ShotFile"
    } catch {
        Write-Log WARN "保存截图失败: $($_.Exception.Message)"
    }
}

function Write-Dump {
    param($Elements)
    try {
        $sw = New-Object System.IO.StreamWriter($DumpFile, $false, [System.Text.Encoding]::UTF8)
        $sw.WriteLine("共 $($Elements.Count) 个元素, 时间 $(Get-Date)")
        if ($script:MainWindow) {
            $mw = $script:MainWindow
            $sw.WriteLine("主窗口: hwnd=$($mw.Hwnd) pid=$($mw.Pid) rect=$($mw.Left),$($mw.Top) $($mw.Width)x$($mw.Height)")
        }
        $sw.WriteLine('---- 与规则匹配的候选 ----')
        foreach ($rgx in @($ClaimRegex, $ClaimedRegex, $RightsEntryRegex, $MenuButtonRegex, $RightsDialogRegex)) {
            $sw.WriteLine("[规则: $rgx]")
            foreach ($e in $Elements) {
                if ($e.Name -and $e.Name -match $rgx) {
                    $sw.WriteLine("  Type=$($e.Type) Name=[$($e.Name)] Offscreen=$($e.Offscreen) Enabled=$($e.Enabled) Rect=$($e.Rect)")
                }
            }
        }
        $sw.WriteLine('---- 全部可交互控件 ----')
        $allowed = @('Button', 'Hyperlink', 'ListItem', 'TreeItem', 'MenuItem', 'TabItem', 'Window', 'Text', 'StatusBar')
        foreach ($e in $Elements) {
            if ($allowed -contains $e.Type) {
                $sw.WriteLine("Type=$($e.Type) Name=[$($e.Name)] Offscreen=$($e.Offscreen) Enabled=$($e.Enabled) Rect=$($e.Rect)")
            }
        }
        $sw.Dispose()
        Write-Log INFO "控件树已导出: $DumpFile"
    } catch {
        Write-Log WARN "导出控件树失败: $($_.Exception.Message)"
    }
}

# ==================== 时间窗口与标记 ====================
function Get-TodayRefreshAt {
    $now = Get-Date
    return (Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $RefreshHour -Minute $RefreshMinute -Second 0)
}

function Get-ClaimWindowKey {
    $now = Get-Date
    $refresh = Get-TodayRefreshAt
    if ($now -lt $refresh) { return $refresh.AddDays(-1).ToString('yyyy-MM-dd') }
    return $refresh.ToString('yyyy-MM-dd')
}

function Set-ClaimedMarker {
    param([string]$Key)
    if ($DryRun) { Write-Log INFO '[DryRun] 不写标记'; return }
    try {
        Set-Content -Path $MarkerFile -Value $Key -Encoding utf8
        Write-Log INFO "已写标记: $MarkerFile = $Key"
    } catch {
        Write-Log ERROR "写标记失败: $($_.Exception.Message)"
        exit 3
    }
}

# ==================== 进程与窗口 ====================
function Test-QoderPid {
    param([int]$ProcId)
    if ($ProcId -le 0) { return $false }
    if ($script:PidCache.ContainsKey($ProcId)) { return $script:PidCache[$ProcId] }
    $ok = $false
    try {
        $p = Get-Process -Id $ProcId -ErrorAction Stop
        $ok = ($p.ProcessName -eq $QoderProcessName)
    } catch { $ok = $false }
    $script:PidCache[$ProcId] = $ok
    return $ok
}

function Get-QoderWindows {
    $script:WindowRows = New-Object System.Collections.Generic.List[object]
    $cb = [Native.Win32+EnumWindowsProc] {
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        $wpid = 0
        [void][Native.Win32]::GetWindowThreadProcessId($hWnd, [ref]$wpid)
        if ((Test-QoderPid ([int]$wpid)) -and [Native.Win32]::IsWindowVisible($hWnd)) {
            $title = New-Object System.Text.StringBuilder 512
            [void][Native.Win32]::GetWindowText($hWnd, $title, 512)
            $cls = New-Object System.Text.StringBuilder 256
            [void][Native.Win32]::GetClassName($hWnd, $cls, 256)
            $rect = New-Object Native.Win32+RECT
            [void][Native.Win32]::GetWindowRect($hWnd, [ref]$rect)
            $w = $rect.Right - $rect.Left
            $h = $rect.Bottom - $rect.Top
            $script:WindowRows.Add([pscustomobject]@{
                Hwnd = $hWnd; Pid = [int]$wpid; Title = $title.ToString(); Class = $cls.ToString()
                Left = $rect.Left; Top = $rect.Top; Width = $w; Height = $h; Area = ($w * $h)
                Iconic = [Native.Win32]::IsIconic($hWnd)
            })
        }
        return $true
    }
    [void][Native.Win32]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:WindowRows
}

function Get-QoderMainWindow {
    $wins = @(Get-QoderWindows)
    # 主窗口最小化时 GetWindowRect 可能偏小, 标题精确为 Qoder 的窗口优先, 不强制面积
    $candidates = @($wins | Where-Object {
        $_.Class -eq 'Chrome_WidgetWin_1' -and $_.Title -eq 'Qoder'
    })
    if ($candidates.Count -eq 0) {
        $candidates = @($wins | Where-Object {
            $_.Class -eq 'Chrome_WidgetWin_1' -and $_.Title -notmatch 'Companion|Desktop Pet' -and $_.Area -gt 200000
        })
    }
    if ($candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object Area -Descending | Select-Object -First 1)
}

function Get-ForegroundInfo {
    $hWnd = [Native.Win32]::GetForegroundWindow()
    $wpid = 0
    [void][Native.Win32]::GetWindowThreadProcessId($hWnd, [ref]$wpid)
    $title = New-Object System.Text.StringBuilder 512
    [void][Native.Win32]::GetWindowText($hWnd, $title, 512)
    $root = [Native.Win32]::GetAncestor($hWnd, 2)
    return [pscustomobject]@{ Hwnd = $hWnd; Root = $root; Pid = [int]$wpid; Title = $title.ToString() }
}

function Test-QoderForeground {
    $fg = Get-ForegroundInfo
    return (Test-QoderPid $fg.Pid)
}

function Activate-Qoder {
    param($Main)
    if ($null -eq $Main -or $Main.Hwnd -eq [IntPtr]::Zero) { return $false }
    if ($Main.Iconic) { [void][Native.Win32]::ShowWindow($Main.Hwnd, 9) }
    if (-not [Native.Win32]::IsWindowVisible($Main.Hwnd)) { [void][Native.Win32]::ShowWindow($Main.Hwnd, 5) }

    $fg = Get-ForegroundInfo
    if ($fg.Root -eq $Main.Hwnd) { return $true }

    # ALT 解除前台锁定; AttachThreadInput 提高 SetForegroundWindow 成功率
    [Native.Win32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [Native.Win32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    $fgPid = 0
    $fgThread = [Native.Win32]::GetWindowThreadProcessId([Native.Win32]::GetForegroundWindow(), [ref]$fgPid)
    $curThread = [Native.Win32]::GetCurrentThreadId()
    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $curThread) {
        $attached = [Native.Win32]::AttachThreadInput($curThread, $fgThread, $true)
    }
    [void][Native.Win32]::SetForegroundWindow($Main.Hwnd)
    [void][Native.Win32]::BringWindowToTop($Main.Hwnd)
    if ($attached) { [void][Native.Win32]::AttachThreadInput($curThread, $fgThread, $false) }
    Start-Sleep -Milliseconds 500
    return (Test-QoderForeground)
}

function Find-QoderExe {
    if ($ExePath -and (Test-Path $ExePath)) { return $ExePath }
    $p = Get-Process -Name $QoderProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p -and $p.Path) { return $p.Path }
    foreach ($c in $ExeCandidates) { if (Test-Path $c) { return $c } }
    foreach ($k in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Qoder*' } | Select-Object -First 1
        if ($hit -and $hit.DisplayIcon) {
            return (($hit.DisplayIcon -split ',')[0]).Trim().Trim('"')
        }
    }
    return $null
}

# ==================== UIA 扫描 ====================
function Get-AllElements {
    $out = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $wins = @(Get-QoderWindows)
    Write-Log DEBUG "Get-AllElements: 顶层窗口数 $($wins.Count)"
    foreach ($w in $wins) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($w.Hwnd)
            if (-not $root) { continue }
            $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
            $stack = New-Object System.Collections.Stack
            $stack.Push($root)
            while ($stack.Count -gt 0) {
                $el = $stack.Pop()
                try {
                    $cur = $el.Current
                    $rid = ''
                    try { $rid = ($el.GetRuntimeId() -join '.') } catch { }
                    if (-not $rid) { $rid = "$($w.Hwnd):$($cur.Name):$($cur.BoundingRectangle)" }
                    if ($seen.Add($rid)) {
                        $out.Add([pscustomobject]@{
                            Element = $el
                            Type = ($cur.ControlType.ProgrammaticName -replace 'ControlType\.', '')
                            Name = [string]$cur.Name
                            Rect = $cur.BoundingRectangle
                            Offscreen = $cur.IsOffscreen
                            Enabled = $cur.IsEnabled
                            Hwnd = $w.Hwnd
                            WinTitle = $w.Title
                        })
                    }
                    $child = $walker.GetFirstChild($el)
                    while ($child) { $stack.Push($child); $child = $walker.GetNextSibling($child) }
                } catch { }
            }
        } catch { }
    }
    return $out
}

function Get-RightsDialog {
    param($Elements)
    $cands = @($Elements | Where-Object {
        $_.Type -eq 'Window' -and -not $_.Offscreen -and -not $_.Rect.IsEmpty -and
        $_.Name -match $RightsDialogRegex -and $_.Rect.Width -gt 300 -and $_.Rect.Height -gt 300
    })
    if ($cands.Count -eq 0) { return $null }
    return ($cands | Sort-Object { $_.Rect.Width * $_.Rect.Height } -Descending | Select-Object -First 1)
}

function Find-RightsMenuItem {
    param($Elements)
    $cands = @($Elements | Where-Object {
        $_.Name -match $RightsEntryRegex -and -not $_.Offscreen -and -not $_.Rect.IsEmpty -and
        (($_.Type -eq 'MenuItem') -or ($_.Type -eq 'Button' -and $_.Rect.Width -lt 500 -and $_.Rect.Height -lt 100))
    })
    if ($cands.Count -eq 0) { return $null }
    return ($cands | Sort-Object `
        @{ Expression = { if ($_.Type -eq 'MenuItem') { 0 } else { 1 } } }, `
        @{ Expression = { $_.Rect.Width * $_.Rect.Height } } | Select-Object -First 1)
}

function Find-MenuButton {
    param($Elements)
    $cands = @($Elements | Where-Object {
        $_.Type -eq 'Button' -and $_.Name -match $MenuButtonRegex -and -not $_.Offscreen -and
        -not $_.Rect.IsEmpty -and $_.Rect.Width -ge 20 -and $_.Rect.Height -ge 20
    })
    if ($cands.Count -eq 0) { return $null }
    # 新版有两个: 左下角整块用户区(宽 372)和 30x30 小按钮; 优先整块区域
    return ($cands | Sort-Object `
        @{ Expression = { if ($_.Rect.Width -ge 300) { 0 } else { 1 } } }, `
        @{ Expression = { $_.Rect.Width * $_.Rect.Height } } | Select-Object -First 1)
}

function Test-InRect {
    param($Inner, $Outer)
    if ($null -eq $Inner -or $null -eq $Outer -or $Inner.IsEmpty -or $Outer.IsEmpty) { return $false }
    $tol = 2
    return ($Inner.X -ge ($Outer.X - $tol) -and
            $Inner.Y -ge ($Outer.Y - $tol) -and
            ($Inner.X + $Inner.Width) -le ($Outer.X + $Outer.Width + $tol) -and
            ($Inner.Y + $Inner.Height) -le ($Outer.Y + $Outer.Height + $tol))
}

function Get-ClaimButton {
    param($Elements, $DialogRect)
    $cands = @($Elements | Where-Object {
        $_.Type -eq 'Button' -and $_.Name -match $ClaimRegex -and -not $_.Offscreen -and
        (Test-InRect $_.Rect $DialogRect)
    })
    if ($cands.Count -eq 0) { return $null }
    return ($cands | Sort-Object { $_.Rect.Width * $_.Rect.Height } | Select-Object -First 1)
}

function Get-ClaimedEvidence {
    param($Elements, $DialogRect)
    $cands = @($Elements | Where-Object {
        $_.Name -and $_.Name -match $ClaimedRegex -and -not $_.Offscreen -and
        ($_.Type -in @('Button', 'Text', 'StatusBar', 'Pane')) -and
        (Test-InRect $_.Rect $DialogRect)
    })
    if ($cands.Count -eq 0) { return $null }
    $best = $cands | Sort-Object `
        @{ Expression = { if ($_.Type -eq 'Button') { 0 } else { 1 } } }, `
        @{ Expression = { $_.Rect.Width * $_.Rect.Height } } | Select-Object -First 1
    return $best.Name
}

function Get-SuccessToast {
    param($Elements)
    # 领取成功后可能出现短暂 toast/StatusBar; 只接受小尺寸、短文本, 避免误匹配聊天大段内容
    $cands = @($Elements | Where-Object {
        $_.Name -and $_.Name -match '领取成功|Credits 已到账' -and -not $_.Offscreen -and
        $_.Name.Length -lt 80 -and -not $_.Rect.IsEmpty -and
        ($_.Type -in @('Button', 'Text', 'StatusBar')) -and
        ($_.Rect.Width * $_.Rect.Height) -lt 200000
    })
    if ($cands.Count -eq 0) { return $null }
    return ($cands | Select-Object -First 1).Name
}

# ==================== 点击 ====================
function Invoke-Click {
    param($Element, [switch]$ForceMouse, [int]$OffsetX = -1)
    try {
        $cur = $Element.Current
        $name = [string]$cur.Name
        $rect = $cur.BoundingRectangle
    } catch {
        Write-Log WARN '无法读取控件坐标, 跳过点击'
        return $false
    }
    if ($rect.IsEmpty -or $rect.Width -lt 2 -or $rect.Height -lt 2) {
        Write-Log WARN "控件坐标无效, 跳过点击: [$name]"
        return $false
    }
    if ($OffsetX -ge 0 -and $OffsetX -lt $rect.Width) {
        $x = [int]($rect.X + $OffsetX)
    } else {
        $x = [int]($rect.X + $rect.Width / 2)
    }
    $y = [int]($rect.Y + $rect.Height / 2)
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($x -lt $vs.Left -or $y -lt $vs.Top -or $x -ge ($vs.Left + $vs.Width) -or $y -ge ($vs.Top + $vs.Height)) {
        Write-Log WARN "控件中心 ($x,$y) 超出屏幕, 跳过点击: [$name]"
        return $false
    }

    $pt = New-Object Native.Win32+POINT
    $pt.X = $x; $pt.Y = $y
    $hit = [Native.Win32]::WindowFromPoint($pt)
    $root = [Native.Win32]::GetAncestor($hit, 2)
    $wpid = 0
    [void][Native.Win32]::GetWindowThreadProcessId($root, [ref]$wpid)
    if (-not (Test-QoderPid ([int]$wpid))) {
        Write-Log WARN "坐标 ($x,$y) 处不是 Qoder 窗口(pid=$wpid), 跳过点击: [$name]"
        return $false
    }

    if (-not $ForceMouse) {
        try {
            $pattern = $null
            if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
                $pattern.Invoke()
                Write-Log INFO "[invoke] $name"
                return $true
            }
        } catch { }
    }

    [void][Native.Win32]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 120
    [Native.Win32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Native.Win32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Write-Log INFO "[click] 鼠标点击 ($x,$y) rect=($([int]$rect.X),$([int]$rect.Y) $([int]$rect.Width)x$([int]$rect.Height)) name=[$name]"
    return $true
}

function Close-RightsDialog {
    param($Elements, $DialogRect)
    $closeNames = @('关闭活动', '关闭')
    $cands = @($Elements | Where-Object {
        $_.Type -eq 'Button' -and $_.Name -in $closeNames -and -not $_.Offscreen -and
        (Test-InRect $_.Rect $DialogRect)
    })
    if ($cands.Count -eq 0) { return }
    $btn = $cands | Sort-Object @{ Expression = { if ($_.Name -eq '关闭活动') { 0 } else { 1 } } } | Select-Object -First 1
    try {
        $pattern = $null
        if ($btn.Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
            $pattern.Invoke()
            Write-Log INFO "关闭权益活动弹层: [$($btn.Name)]"
            return
        }
    } catch { }
    [void](Invoke-Click $btn.Element -ForceMouse)
    Write-Log INFO "关闭权益活动弹层: [$($btn.Name)]"
}

# ==================== 主流程 ====================
Write-Log INFO ('===== 启动 (DryRun={0}, DumpTree={1}) =====' -f [bool]$DryRun, [bool]$DumpTree)

$markerKey = Get-ClaimWindowKey
if (-not $DryRun -and -not $DumpTree -and (Test-Path $MarkerFile)) {
    $saved = ([string](Get-Content -Raw -Path $MarkerFile)).Trim()
    if ($saved -eq $markerKey) {
        Write-Log INFO "标记文件显示当前领取窗口($markerKey)已处理, 直接退出"
        exit 0
    }
}

$now = Get-Date
$claimAt = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $ClaimHour -Minute $ClaimMinute -Second 0
if (-not $DryRun -and -not $DumpTree -and $now -lt $claimAt) {
    $waitMinutes = [math]::Round(($claimAt - $now).TotalMinutes, 1)
    if ($waitMinutes -gt $MaxWaitMinutes) {
        Write-Log INFO "未到 $($claimAt.ToString('HH:mm')), 还有 $waitMinutes 分钟, 超过等待上限 $MaxWaitMinutes 分钟, 退出"
        exit 2
    }
    Write-Log INFO "未到 $($claimAt.ToString('HH:mm')), 等待中..."
    while ((Get-Date) -lt $claimAt) { Start-Sleep -Seconds 30 }
}
$windowKey = Get-ClaimWindowKey

# 定位 Qoder 主窗口
$main = Get-QoderMainWindow
if (-not $main) {
    $exe = Find-QoderExe
    $proc = Get-Process -Name $QoderProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) {
        if (-not $exe) {
            Write-Log ERROR '找不到 Qoder.exe, 请用 -ExePath 指定路径'
            exit 4
        }
        Write-Log INFO "Qoder 未运行, 启动: $exe (带辅助功能参数)"
        Start-Process -FilePath $exe -ArgumentList '--force-renderer-accessibility'
    }
    for ($i = 1; $i -le 60; $i++) {
        Start-Sleep -Seconds 1
        $main = Get-QoderMainWindow
        if ($main) { break }
    }
}
if (-not $main) {
    Write-Log ERROR '等待 Qoder 主窗口超时'
    Save-Screenshot
    exit 4
}
$script:MainWindow = $main
Write-Log INFO "Qoder 主窗口: hwnd=$($main.Hwnd) pid=$($main.Pid) rect=$($main.Left),$($main.Top) $($main.Width)x$($main.Height)"

# 注册 UIA 焦点事件, 让 Chromium 保持辅助功能树
$script:focusHandler = [System.Windows.Automation.AutomationFocusChangedEventHandler] {
    param($sender, $e)
}
try { [System.Windows.Automation.Automation]::AddAutomationFocusChangedEventHandler($script:focusHandler) } catch { }

$activated = Activate-Qoder $main
if (-not $activated) {
    Write-Log WARN 'Qoder 未能调到前台, 本轮不点击(点击前还会校验坐标处窗口归属)'
}

$all = @()
for ($try = 1; $try -le 3; $try++) {
    $all = @(Get-AllElements)
    Write-Log INFO "第 $try 次扫描: $($all.Count) 个元素"
    if ($all.Count -gt 20) { break }
    Start-Sleep -Seconds 10
}
try { [System.Windows.Automation.Automation]::RemoveAutomationFocusChangedEventHandler($script:focusHandler) } catch { }
if ($all.Count -le 20) {
    Write-Log WARN 'UIA 元素过少, a11y 树未重建; 放弃本次'
    Save-Screenshot
    exit 4
}

if ($DumpTree) { Write-Dump $all; exit 0 }

# ---- 打开/定位权益活动弹层 ----
$dialog = Get-RightsDialog $all
$openedByUs = $false

if (-not $dialog) {
    if ($DryRun) {
        Write-Log INFO '[DryRun] 权益活动弹层未打开; 正式运行会点击 打开用户菜单 -> 权益中心'
        exit 0
    }
    for ($attempt = 1; $attempt -le 3 -and -not $dialog; $attempt++) {
        if (-not (Activate-Qoder $main)) {
            Write-Log WARN 'Qoder 未能调到前台, 本轮不点击(点击前还会校验坐标处窗口归属)'
            Start-Sleep -Seconds 2
            continue
        }
        $menuItem = Find-RightsMenuItem $all
        if (-not $menuItem) {
            $menuBtn = Find-MenuButton $all
            if (-not $menuBtn) {
                Write-Log WARN '找不到左下角「打开用户菜单」按钮, 界面可能改版; 控件树留证'
                Write-Dump $all
                Save-Screenshot
                break
            }
            Write-Log INFO "第 $attempt 次打开用户菜单: [$($menuBtn.Name)]"
            if (-not (Invoke-Click $menuBtn.Element -ForceMouse -OffsetX 80)) { Start-Sleep -Seconds 2; continue }
            $openedByUs = $true
            for ($i = 1; $i -le 5; $i++) {
                Start-Sleep -Seconds 2
                $all = @(Get-AllElements)
                $menuItem = Find-RightsMenuItem $all
                if ($menuItem) { break }
            }
            if (-not $menuItem) {
                Write-Log WARN '用户菜单已打开但未找到「权益中心」菜单项(可能未到开放时间); 不写标记, 等待下轮重试'
                continue
            }
        }
        Write-Log INFO "点击权益中心: [$($menuItem.Name)] rect=($([int]$menuItem.Rect.X),$([int]$menuItem.Rect.Y) $([int]$menuItem.Rect.Width)x$([int]$menuItem.Rect.Height))"
        if (-not (Invoke-Click $menuItem.Element -ForceMouse)) { Start-Sleep -Seconds 2; continue }
        $openedByUs = $true
        for ($i = 1; $i -le 15; $i++) {
            Start-Sleep -Seconds 2
            $all = @(Get-AllElements)
            $dialog = Get-RightsDialog $all
            if ($dialog) { Write-Log INFO "权益活动弹层已打开(第 $i 次检测)"; break }
        }
        if (-not $dialog) {
            Write-Log WARN '点击权益中心后未出现权益活动弹层'
            $all = @(Get-AllElements)
        }
    }
}
if (-not $dialog) {
    Write-Log INFO '没有找到可用的权益入口(可能未到开放时间), 不写标记, 等待下轮重试'
    exit 0
}

# ---- 等待弹层内容: 领取按钮 或 已领取证据 ----
$claimBtn = $null
$evidence = $null
$dialogRect = $null
for ($i = 1; $i -le 20; $i++) {
    $dialog = Get-RightsDialog $all
    if (-not $dialog) { break }
    $dialogRect = $dialog.Rect
    $claimBtn = Get-ClaimButton $all $dialogRect
    $evidence = Get-ClaimedEvidence $all $dialogRect
    if ($claimBtn -or $evidence) { break }
    Start-Sleep -Seconds 2
    $all = @(Get-AllElements)
}
$dialog = Get-RightsDialog $all
if (-not $dialog) {
    Write-Log WARN '权益活动弹层在等待内容时消失'
    exit 3
}
$dialogRect = $dialog.Rect

if ($evidence) {
    $now = Get-Date
    if ($now -lt (Get-TodayRefreshAt)) {
        Write-Log INFO "检测到已领取文案 [$evidence], 但当前仍在上一领取窗口, 不写标记"
    } elseif ($DryRun) {
        Write-Log INFO "[DryRun] 检测到已领取文案 [$evidence], 当前窗口($windowKey)已完成; 不写标记"
    } else {
        Write-Log INFO "检测到已领取文案 [$evidence], 当前窗口($windowKey)已完成, 写标记退出"
        Set-ClaimedMarker $windowKey
    }
    if ($openedByUs) { Close-RightsDialog $all $dialogRect }
    exit 0
}

if ($claimBtn) {
    if ($DryRun) {
        Write-Log INFO "[DryRun] 找到领取按钮 [$($claimBtn.Name)], 不点击"
        exit 0
    }
    $success = $false
    for ($attempt = 1; $attempt -le 3 -and -not $success; $attempt++) {
        $dialog = Get-RightsDialog $all
        if (-not $dialog) { break }
        $dialogRect = $dialog.Rect
        $claimBtn = Get-ClaimButton $all $dialogRect
        if (-not $claimBtn) { break }
        Write-Log INFO "第 $attempt 次点击领取按钮: [$($claimBtn.Name)]"
        if (-not (Invoke-Click $claimBtn.Element -ForceMouse)) {
            Start-Sleep -Seconds 2
            $all = @(Get-AllElements)
            continue
        }
        for ($i = 1; $i -le 8; $i++) {
            Start-Sleep -Seconds 2
            $all = @(Get-AllElements)
            $dialog = Get-RightsDialog $all
            $evidence = $null
            if ($dialog) {
                $dialogRect = $dialog.Rect
                $evidence = Get-ClaimedEvidence $all $dialogRect
            }
            if (-not $evidence) { $evidence = Get-SuccessToast $all }
            if ($evidence) { $success = $true; break }
        }
        if (-not $success) { $all = @(Get-AllElements) }
    }
    if ($success) {
        Write-Log INFO "检测到已领取文案 [$evidence], 领取成功, 写标记"
        Set-ClaimedMarker $windowKey
        if ($openedByUs) {
            $dialog = Get-RightsDialog $all
            if ($dialog) { Close-RightsDialog $all $dialog.Rect }
        }
        exit 0
    }
    Write-Log WARN '点击领取后未检测到「已领取/领取成功」证据, 结果未知; 不写标记; 截图+控件树留证'
    Save-Screenshot
    Write-Dump $all
    exit 3
}

Write-Log WARN '权益活动弹层里既没有「领取」按钮, 也没有「已领取」证据; 不写标记, 等待下轮重试'
Save-Screenshot
Write-Dump $all
exit 3
