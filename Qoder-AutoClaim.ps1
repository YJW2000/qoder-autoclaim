<#
Qoder自动签到脚本 (Qoder AutoClaim) - Qoder 每日积分自动领取
规则: 每日 10:00 (UTC+8) 刷新后, 桌面端左下角「打开用户菜单」->「权益中心，有权益待领取」
     -> 权益活动弹层 -> 点击「领取」。每个窗口限领一次, 错过不补。
     领取成功的证据: 弹层内按钮变为「已领取」且出现「领取成功，Credits 已到账」。
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
        3=入口或弹层流程未走通  4=环境异常
诊断文件(每次覆盖): %LOCALAPPDATA%\QoderAutoClaim\{autoclaim.log, uia-latest.txt, screen-latest.png}

注意: 本文件必须保持 UTF-8 with BOM, 否则 Windows PowerShell 5.1 会把中文读成乱码,
      导致控件名匹配和日志全部失效。
#>
param(
    [switch]$DryRun,
    [switch]$DumpTree,
    [int]$MaxWaitMinutes = 50,
    [string]$ExePath
)

$ErrorActionPreference = 'Stop'

# ==================== 可调配置 ====================
$ClaimHour     = 10          # 每日领取时间(本机时区): 每天 10:05 由计划任务触发
$ClaimMinute   = 5
$RefreshHour   = 10          # Qoder 每日 10:00 (UTC+8) 刷新领取窗口
$RefreshMinute = 0
$QoderProcName = 'Qoder'
$ExeCandidates = @("$env:LOCALAPPDATA\Programs\Qoder\Qoder.exe")

# 控件名称匹配规则 (依据 -DumpTree / probe 结果调整)
$MenuButtonRegex  = '^打开用户菜单$'                  # 左下角用户菜单按钮
$RightsEntryRegex = '权益中心'                          # 用户菜单里的「权益中心，有权益待领取」
$RightsDialogName = '权益活动内容'                      # 权益活动弹层窗口名
$ClaimRegex       = '^领取$'                            # 弹层内的领取按钮(精确匹配, 避免误点「每天领 100 Credits」)
$ClaimedRegex     = '已领取|领取成功|Credits 已到账|Claimed|明日再来|明天再来|今日已领'
$NoClickRegex     = '关闭|最小化|最大化|刷新用量|查看详情'   # 这些按钮永远不当领取入口

$LogDir      = Join-Path $env:LOCALAPPDATA 'QoderAutoClaim'
$LogFile     = Join-Path $LogDir 'autoclaim.log'
$MarkerFile  = Join-Path $LogDir 'last-claim.txt'
$DumpFile    = Join-Path $LogDir 'uia-latest.txt'
$ShotFile    = Join-Path $LogDir 'screen-latest.png'
# ==================================================

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Level, [string]$Msg)
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
    Write-Host $line
}

Add-Type -Namespace Native -Name User32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT pt);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
public delegate bool EnumProc(IntPtr hWnd, IntPtr lp);
'@

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Save-Screenshot {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
        $bmp.Save($ShotFile, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        Write-Log INFO "已保存截图: $ShotFile"
    } catch { Write-Log WARN "截图失败: $($_.Exception.Message)" }
}

$script:walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

# TreeWalker 逐节点遍历(对 Chromium 忙状态鲁棒), 覆盖进程的全部顶层窗口
function Get-AllElements {
    param([int]$ProcId, [int]$MaxNodes = 15000)
    # 用 EnumWindows 而非 UIA RootElement.FindAll: 后者漏掉 Chromium 的弹层 HWND(如权益活动弹层),
    # 弹层内容都在独立顶层窗口里, 漏枚举会导致永远找不到领取按钮
    $script:_wins = @()
    $cb = [Native.User32+EnumProc] { param($h, $lp)
        $p = 0
        $null = [Native.User32]::GetWindowThreadProcessId($h, [ref]$p)
        if ($p -eq $ProcId) { $script:_wins += $h }
        return $true
    }
    $null = [Native.User32]::EnumWindows($cb, [IntPtr]::Zero)
    $out = New-Object System.Collections.ArrayList
    Write-Log DEBUG "Get-AllElements: 顶层窗口数 $($script:_wins.Count)"
    foreach ($h in $script:_wins) {
        try {
            $w = [System.Windows.Automation.AutomationElement]::FromHandle($h)
        } catch { continue }
        $stack = New-Object System.Collections.Stack
        $stack.Push($w)
        while ($stack.Count -gt 0 -and $out.Count -lt $MaxNodes) {
            $n = $stack.Pop()
            [void]$out.Add($n)
            try {
                $ch = $script:walker.GetFirstChild($n)
                while ($ch -and $out.Count -lt $MaxNodes) {
                    $stack.Push($ch)
                    $ch = $script:walker.GetNextSibling($ch)
                }
            } catch { }
        }
    }
    return $out
}

function Get-CName { param($e) try { return [string]$e.Current.Name } catch { return '' } }

function Test-InRect {
    param($Rect, $Outer)
    if ($null -eq $Rect -or $null -eq $Outer) { return $false }
    if ($Rect.IsEmpty -or $Outer.IsEmpty) { return $false }
    # 必须完全包含在弹层内: 聊天区大段文字的中心也可能落在弹层矩形里, 用中心点判断会误匹配
    $tol = 2
    return ($Rect.X -ge ($Outer.X - $tol) -and $Rect.Y -ge ($Outer.Y - $tol) -and
            ($Rect.X + $Rect.Width) -le ($Outer.X + $Outer.Width + $tol) -and
            ($Rect.Y + $Rect.Height) -le ($Outer.Y + $Outer.Height + $tol))
}

function Find-Interactive {
    param($Elements, [string]$Regex, [switch]$SkipNoClickFilter)
    $allowed = @('ControlType.Button', 'ControlType.Hyperlink', 'ControlType.ListItem',
                 'ControlType.TreeItem', 'ControlType.MenuItem', 'ControlType.TabItem')
    foreach ($e in $Elements) {
        try {
            $c = $e.Current
            $n = [string]$c.Name
            if (-not $n) { continue }
            if ($allowed -notcontains $c.ControlType.ProgrammaticName) { continue }
            if ($n -match $ClaimedRegex) { continue }
            if (-not $SkipNoClickFilter -and $n -match $NoClickRegex) { continue }
            if ($n -match $Regex) { return $e }
        } catch { }
    }
    return $null
}

function Get-RightsDialog {
    param($Elements)
    foreach ($e in $Elements) {
        try {
            $c = $e.Current
            if ($c.ControlType.ProgrammaticName -eq 'ControlType.Window' -and [string]$c.Name -eq $RightsDialogName) { return $e }
        } catch { }
    }
    return $null
}

function Get-ClaimButton {
    param($Elements, $Rect)
    foreach ($e in $Elements) {
        try {
            $c = $e.Current
            if ($c.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
            if ([string]$c.Name -ne '领取') { continue }
            if (-not (Test-InRect $c.BoundingRectangle $Rect)) { continue }
            return $e
        } catch { }
    }
    return $null
}

function Get-ClaimedEvidence {
    param($Elements, $Rect)
    foreach ($e in $Elements) {
        try {
            $c = $e.Current
            $n = [string]$c.Name
            if (-not $n -or $n -notmatch $ClaimedRegex) { continue }
            if ($c.ControlType.ProgrammaticName -notmatch 'Text|Button|StatusBar') { continue }
            if (-not (Test-InRect $c.BoundingRectangle $Rect)) { continue }
            return $n
        } catch { }
    }
    return $null
}

function Invoke-Click {
    param($e, [switch]$ForceMouse)
    if (-not $ForceMouse) {
        foreach ($p in @([System.Windows.Automation.InvokePattern]::Pattern,
                         [System.Windows.Automation.TogglePattern]::Pattern,
                         [System.Windows.Automation.SelectionItemPattern]::Pattern)) {
            $o = $null
            if ($e.TryGetCurrentPattern($p, [ref]$o)) {
                if ($o -is [System.Windows.Automation.InvokePattern]) { $o.Invoke() }
                elseif ($o -is [System.Windows.Automation.TogglePattern]) { $o.Toggle() }
                else { $o.Select() }
                return $true
            }
        }
    }
    # 鼠标兜底: 需要窗口在前台。Chromium 部分控件 Expand 只翻 aria 不触发 onClick,
    # 菜单项/领取按钮一律走真实鼠标点击(ForceMouse)
    try {
        $r = $e.Current.BoundingRectangle
        if ($r.IsEmpty) { Write-Log WARN '控件矩形为空, 无法点击'; return $false }
        $pt = $null
        try { $pt = $e.GetClickablePoint() } catch { }
        if (-not $pt) { $pt = [System.Windows.Point]::new([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2)) }
        # 点击前确认坐标处窗口属于 Qoder, 防止 Qoder 被其他窗口覆盖时误点(例如用户正在别的应用操作)
        $hit = New-Object Native.User32+POINT
        $hit.X = [int]$pt.X; $hit.Y = [int]$pt.Y
        $winAt = [Native.User32]::WindowFromPoint($hit)
        $rootAt = [Native.User32]::GetAncestor($winAt, 2)
        $rootPid = 0
        $null = [Native.User32]::GetWindowThreadProcessId($rootAt, [ref]$rootPid)
        if ($script:QoderPid -and $rootPid -ne $script:QoderPid) {
            Write-Log WARN ("点击坐标被其他窗口覆盖(该点窗口 PID=$rootPid, Qoder PID=$($script:QoderPid)), 跳过以防误点")
            return $false
        }
        Write-Log INFO ("[click] 鼠标点击 ({0},{1}) rect=({2},{3},{4}x{5}) name=[{6}]" -f [int]$pt.X, [int]$pt.Y, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height, (Get-CName $e))
        [Native.User32]::SetCursorPos([int]$pt.X, [int]$pt.Y) | Out-Null
        Start-Sleep -Milliseconds 150
        [Native.User32]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 60
        [Native.User32]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 800
        return $true
    } catch {
        Write-Log WARN "鼠标点击失败: $($_.Exception.Message)"
        return $false
    }
}

# 恢复最小化/隐藏窗口并真实激活(Chromium 最小化时丢弃 a11y 树, 需要激活后才重建)
function Activate-Qoder {
    param([IntPtr]$Hwnd)
    if ([Native.User32]::IsIconic($Hwnd)) { [Native.User32]::ShowWindow($Hwnd, 9) | Out-Null; Start-Sleep -Milliseconds 800 }
    if (-not [Native.User32]::IsWindowVisible($Hwnd)) { [Native.User32]::ShowWindow($Hwnd, 5) | Out-Null; Start-Sleep -Milliseconds 800 }
    [Native.User32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # ALT 解除前台锁定
    [Native.User32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    # SetForegroundWindow 在用户正在别的窗口输入时会被系统拒绝, AttachThreadInput 可提高成功率
    $fg = [Native.User32]::GetForegroundWindow()
    $fgPid = 0
    $fgThread = [Native.User32]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $curThread = [Native.User32]::GetCurrentThreadId()
    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $curThread) {
        $attached = [Native.User32]::AttachThreadInput($curThread, $fgThread, $true)
    }
    [Native.User32]::SetForegroundWindow($Hwnd) | Out-Null
    [Native.User32]::BringWindowToTop($Hwnd) | Out-Null
    if ($attached) { [Native.User32]::AttachThreadInput($curThread, $fgThread, $false) | Out-Null }
    Start-Sleep -Milliseconds 400
}

function Test-QoderForeground {
    param([int]$ProcId)
    $fgPid = 0
    $null = [Native.User32]::GetWindowThreadProcessId([Native.User32]::GetForegroundWindow(), [ref]$fgPid)
    return ($fgPid -eq $ProcId)
}

function Write-Dump {
    param($Elements)
    $sw = New-Object System.IO.StreamWriter($DumpFile, $false, [System.Text.Encoding]::UTF8)
    $sw.WriteLine("共 $($Elements.Count) 个元素, 时间 $(Get-Date)")
    $sw.WriteLine('---- 与规则匹配的候选 ----')
    foreach ($rgx in @($ClaimRegex, $ClaimedRegex, $RightsEntryRegex, $MenuButtonRegex)) {
        $sw.WriteLine("[规则: $rgx]")
        foreach ($e in $Elements) {
            $n = Get-CName $e
            if ($n -and $n -match $rgx) {
                $c = $e.Current
                $t = $c.ControlType.ProgrammaticName -replace 'ControlType\.', ''
                $sw.WriteLine("  Type=$t Name=[$n] Offscreen=$($c.IsOffscreen)")
            }
        }
    }
    $sw.WriteLine('---- 全部可交互控件 ----')
    $allowed = @('ControlType.Button', 'ControlType.Hyperlink', 'ControlType.ListItem',
                 'ControlType.TreeItem', 'ControlType.MenuItem', 'ControlType.TabItem')
    foreach ($e in $Elements) {
        try {
            $c = $e.Current
            if ($allowed -contains $c.ControlType.ProgrammaticName) {
                $t = $c.ControlType.ProgrammaticName -replace 'ControlType\.', ''
                $sw.WriteLine("Type=$t Name=[$($c.Name)] Offscreen=$($c.IsOffscreen)")
            }
        } catch { }
    }
    $sw.Dispose()
    Write-Log INFO "控件树已导出: $DumpFile"
}

function Set-ClaimedMarker {
    if ($DryRun) { Write-Log INFO '[DryRun] 不写标记'; return }
    Set-Content -Path $MarkerFile -Value $windowKey -Encoding utf8
    Write-Log INFO "已写标记: $MarkerFile = $windowKey"
}

# ==================== 主流程 ====================
Write-Log INFO ('===== 启动 (DryRun={0}, DumpTree={1}) =====' -f [bool]$DryRun, [bool]$DumpTree)

# 领取窗口以每天 10:00 为界(10:00 前属于前一天窗口), 标记按窗口日期记录,
# 避免凌晨检测到上一窗口的「已领取」后误写当天标记、挡掉 10:00 刷新后的真正领取
function Get-ClaimWindowKey {
    $now = Get-Date
    $refreshAt = Get-Date -Hour $RefreshHour -Minute $RefreshMinute -Second 0
    if ($now -lt $refreshAt) { $refreshAt = $refreshAt.AddDays(-1) }
    return $refreshAt.ToString('yyyy-MM-dd')
}
$windowKey = Get-ClaimWindowKey
if (-not $DumpTree -and (Test-Path $MarkerFile)) {
    $last = (Get-Content $MarkerFile -Raw -ErrorAction SilentlyContinue)
    if ($last -and $last.Trim() -eq $windowKey) {
        Write-Log INFO "标记文件显示当前领取窗口($windowKey)已处理, 直接退出"
        exit 0
    }
}

# 等待每日领取窗口
$now = Get-Date
$claimAt = Get-Date -Hour $ClaimHour -Minute $ClaimMinute -Second 0
if (-not $DumpTree -and $now -lt $claimAt) {
    $waitMin = ($claimAt - $now).TotalMinutes
    if ($waitMin -gt $MaxWaitMinutes) {
        Write-Log WARN "距领取开放还有 $([int]$waitMin) 分钟, 超过等待上限 $MaxWaitMinutes 分钟, 退出(由每日定时触发兜底)"
        exit 2
    }
    Write-Log INFO "未到 $($claimAt.ToString('HH:mm')), 等待中..."
    while ((Get-Date) -lt $claimAt) { Start-Sleep -Seconds 30 }
}
# 等待可能跨越 10:00 刷新点, 重新计算当前窗口
$windowKey = Get-ClaimWindowKey

# 定位 Qoder 进程与 exe
$proc = Get-Process -Name $QoderProcName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$exe = $null
if ($proc -and $proc.Path) { $exe = $proc.Path }
if (-not $exe -and $ExePath) {
    if (Test-Path $ExePath) { $exe = $ExePath } else { Write-Log WARN "-ExePath 不存在: $ExePath" }
}
if (-not $exe) {
    foreach ($c in $ExeCandidates) { if (Test-Path $c) { $exe = $c; break } }
}
if (-not $exe) {
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Qoder*' } | Select-Object -First 1
        if ($hit -and $hit.DisplayIcon) { $exe = ($hit.DisplayIcon -split ',')[0]; break }
    }
}
if (-not $exe) { Write-Log ERROR '找不到 Qoder.exe, 请用 -ExePath 指定路径'; exit 4 }

if (-not $proc) {
    Write-Log INFO "Qoder 未运行, 启动: $exe (带辅助功能参数)"
    Start-Process -FilePath $exe -ArgumentList '--force-renderer-accessibility'
}

$deadline = (Get-Date).AddSeconds(120)
$proc = $null
while ($true) {
    $proc = Get-Process -Name $QoderProcName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($proc) { break }
    if ((Get-Date) -gt $deadline) { Write-Log ERROR '等待 Qoder 主窗口超时'; Save-Screenshot; exit 4 }
    Start-Sleep -Seconds 3
}
Write-Log INFO "Qoder 就绪: PID=$($proc.Id)"
$script:QoderPid = $proc.Id

# 注册 UIA 事件监听: 让 Chromium 检测到辅助功能客户端, 否则 a11y 树会在无客户端约 1 分钟后衰减
$script:focusHandler = [System.Windows.Automation.AutomationFocusChangedEventHandler]{ param($s, $e) }
[System.Windows.Automation.Automation]::AddAutomationFocusChangedEventHandler($script:focusHandler)

# 激活 + 扫描 (最小化的 Chromium 窗口 a11y 树为空, 需要激活并等待重建)
$all = @()
for ($try = 1; $try -le 10; $try++) {
    Activate-Qoder $proc.MainWindowHandle
    $all = @(Get-AllElements -ProcId $proc.Id)
    Write-Log INFO "第 $try 次扫描: $($all.Count) 个元素"
    if ($all.Count -gt 20) { break }
    Start-Sleep -Seconds 10
}
[System.Windows.Automation.Automation]::RemoveAutomationFocusChangedEventHandler($script:focusHandler)
if ($all.Count -le 20) {
    Write-Log WARN 'UIA 元素过少, a11y 树未重建; 放弃本次(明日定时任务会再试)'
    Save-Screenshot
    exit 4
}

if ($DumpTree) { Write-Dump $all; exit 0 }

# ---- 定位/打开权益活动弹层 ----
$dialog = Get-RightsDialog $all
$openedByUs = $false

if (-not $dialog) {
    if ($DryRun) {
        Write-Log INFO '[DryRun] 权益活动弹层未打开; 正式运行会点击 打开用户菜单 -> 权益中心'
        exit 0
    }
    for ($attempt = 1; $attempt -le 3 -and -not $dialog; $attempt++) {
        Activate-Qoder $proc.MainWindowHandle
        if (-not (Test-QoderForeground $proc.Id)) {
            Write-Log WARN 'Qoder 未能调到前台, 本轮不点击(点击前还会校验坐标处窗口归属)'
            Start-Sleep -Seconds 2
            continue
        }
        # 菜单若已打开(上一轮点开了但没点中菜单项), 直接找菜单项, 避免再点一次把它关掉
        $menuItem = Find-Interactive $all $RightsEntryRegex -SkipNoClickFilter
        if (-not $menuItem) {
            $menuBtn = Find-Interactive $all $MenuButtonRegex
            if (-not $menuBtn) {
                Write-Log WARN '找不到左下角「打开用户菜单」按钮, 界面可能改版; 控件树留证'
                Write-Dump $all
                Save-Screenshot
                break
            }
            Write-Log INFO "第 $attempt 次打开用户菜单: [$(Get-CName $menuBtn)]"
            if (-not (Invoke-Click $menuBtn -ForceMouse)) { Start-Sleep -Seconds 2; continue }
            $openedByUs = $true
            for ($i = 1; $i -le 5; $i++) {
                Start-Sleep -Seconds 2
                $all = @(Get-AllElements -ProcId $proc.Id)
                $menuItem = Find-Interactive $all $RightsEntryRegex -SkipNoClickFilter
                if ($menuItem) { break }
            }
            if (-not $menuItem) {
                Write-Log WARN '用户菜单已打开但未找到「权益中心」菜单项(可能未到开放时间); 不写标记, 等待下轮重试'
                continue
            }
        }
        Write-Log INFO "点击权益中心: [$(Get-CName $menuItem)]"
        if (-not (Invoke-Click $menuItem -ForceMouse)) { Start-Sleep -Seconds 2; continue }
        $openedByUs = $true
        # 弹层是独立 HWND, 加载需要时间(会先显示「正在加载活动…」)
        for ($i = 1; $i -le 15; $i++) {
            Start-Sleep -Seconds 2
            $all = @(Get-AllElements -ProcId $proc.Id)
            $dialog = Get-RightsDialog $all
            if ($dialog) { Write-Log INFO "权益活动弹层已打开(第 $i 次检测)"; break }
        }
        if (-not $dialog) {
            Write-Log WARN '点击权益中心后未出现权益活动弹层'
            $all = @(Get-AllElements -ProcId $proc.Id)
        }
    }
}
if (-not $dialog) {
    Write-Log INFO '没有找到可用的权益入口(可能未到开放时间), 不写标记, 等待下轮重试'
    exit 0
}

# 等待弹层内容加载: 直到出现「领取」按钮或「已领取」证据
$claimBtn = $null
$evidence = $null
$dr = $null
for ($i = 1; $i -le 20; $i++) {
    $dialog = Get-RightsDialog $all
    if (-not $dialog) { break }
    $dr = $dialog.Current.BoundingRectangle
    $claimBtn = Get-ClaimButton $all $dr
    $evidence = Get-ClaimedEvidence $all $dr
    if ($claimBtn -or $evidence) { break }
    Start-Sleep -Seconds 2
    $all = @(Get-AllElements -ProcId $proc.Id)
}
$dialog = Get-RightsDialog $all
if (-not $dialog) {
    Write-Log WARN '权益活动弹层在加载过程中关闭, 无法判断领取状态; 不写标记'
    Write-Dump $all
    Save-Screenshot
    exit 3
}
$dr = $dialog.Current.BoundingRectangle

function Close-RightsDialog {
    param($ProcId)
    if ($DryRun) { return }
    $els = @(Get-AllElements -ProcId $ProcId)
    $dlg = Get-RightsDialog $els
    if (-not $dlg) { return }
    $rect = $dlg.Current.BoundingRectangle
    $btn = $null
    foreach ($e in $els) {
        try {
            $c = $e.Current
            if ($c.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
            if ([string]$c.Name -notmatch '^关闭活动$|^关闭$') { continue }
            if (-not (Test-InRect $c.BoundingRectangle $rect)) { continue }
            $btn = $e; break
        } catch { }
    }
    if ($btn) {
        Write-Log INFO "关闭权益活动弹层: [$(Get-CName $btn)]"
        $null = Invoke-Click $btn
    }
}

# 情况 A: 已领取(可能是本轮之前已手动领取, 或上一窗口状态)
if (-not $claimBtn -and $evidence) {
    $refreshAt = Get-Date -Hour $RefreshHour -Minute $RefreshMinute -Second 0
    if ((Get-Date) -ge $refreshAt) {
        Write-Log INFO "检测到已领取文案 [$evidence], 当前窗口($windowKey)已完成, 写标记退出"
        Set-ClaimedMarker
        if ($openedByUs) { Close-RightsDialog $proc.Id }
        exit 0
    }
    Write-Log INFO "检测到已领取文案 [$evidence], 但当前未到 $($refreshAt.ToString('HH:mm')) 刷新, 属于上一窗口, 不写标记"
    if ($openedByUs) { Close-RightsDialog $proc.Id }
    exit 0
}

# 情况 B: 弹层已加载但没有领取入口, 也不是已领取
if (-not $claimBtn) {
    Write-Log WARN '权益活动弹层未出现「领取」或「已领取」, 页面可能未加载完成或界面改版; 不写标记'
    Write-Dump $all
    Save-Screenshot
    if ($openedByUs) { Close-RightsDialog $proc.Id }
    exit 3
}

# 情况 C: 可领取
if ($DryRun) {
    Write-Log INFO "[DryRun] 将在权益活动弹层点击领取: [$(Get-CName $claimBtn)]"
    exit 0
}

$clicked = $false
for ($round = 1; $round -le 2 -and -not $clicked; $round++) {
    Activate-Qoder $proc.MainWindowHandle
    if (-not (Test-QoderForeground $proc.Id)) {
        Write-Log WARN 'Qoder 未能调到前台, 本轮不点击(点击前还会校验坐标处窗口归属)'
        Start-Sleep -Seconds 2
        continue
    }
    Write-Log INFO "第 $round 次点击领取按钮: [$(Get-CName $claimBtn)]"
    if (Invoke-Click $claimBtn -ForceMouse) { $clicked = $true }
}

if (-not $clicked) {
    Write-Log WARN '领取按钮点击失败; 截图+控件树留证'
    Write-Dump $all
    Save-Screenshot
    if ($openedByUs) { Close-RightsDialog $proc.Id }
    exit 3
}

# 等待明确的领取成功证据(绝不把"按钮消失"直接当成功)
$evidence = $null
for ($i = 1; $i -le 8; $i++) {
    Start-Sleep -Seconds 2
    $all = @(Get-AllElements -ProcId $proc.Id)
    $dialog = Get-RightsDialog $all
    if (-not $dialog) { break }
    $dr = $dialog.Current.BoundingRectangle
    $evidence = Get-ClaimedEvidence $all $dr
    if ($evidence) { break }
    $claimBtn = Get-ClaimButton $all $dr
    Write-Log INFO ("第 {0} 次复核: 领取按钮={1} 成功文案=[{2}]" -f $i, [bool]$claimBtn, $evidence)
}
if ($evidence) {
    Write-Log INFO "检测到已领取文案 [$evidence], 领取成功, 写标记"
    Set-ClaimedMarker
    if ($openedByUs) { Close-RightsDialog $proc.Id }
    exit 0
}

Write-Log WARN '点击领取后未检测到「已领取/领取成功」证据, 结果未知; 不写标记; 截图+控件树留证'
Write-Dump $all
Save-Screenshot
if ($openedByUs) { Close-RightsDialog $proc.Id }
exit 3
