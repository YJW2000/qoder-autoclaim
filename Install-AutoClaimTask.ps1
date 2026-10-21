# 注册 Windows 计划任务: 每天 10:05 自动领取 Qoder 积分 (10:00 UTC+8 刷新)
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File Install-AutoClaimTask.ps1
#       (如遇拒绝访问, 请用管理员 PowerShell 再跑一次)
# 卸载: Unregister-ScheduledTask -TaskName Qoder-AutoClaim -Confirm:$false

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$ScriptPath = Join-Path $ScriptDir 'Qoder-AutoClaim.ps1'
$TaskName  = 'Qoder-AutoClaim'

if (-not (Test-Path $ScriptPath)) {
    throw "未找到主脚本: $ScriptPath"
}

# 通过 VBS 以完全隐藏的方式启动 PowerShell, 避免计划任务闪黑框
$action = New-ScheduledTaskAction -Execute 'wscript.exe' `
    -Argument "`"$ScriptDir\run-hidden.vbs`" `"$ScriptPath`"" `
    -WorkingDirectory $ScriptDir

# 主触发: 每天 10:05 (10:00 刷新后 5 分钟), 之后每小时重试至 12:05 以防首次失败
$triggerDaily = New-ScheduledTaskTrigger -Daily -At '10:05'
$triggerDaily.Repetition = (New-ScheduledTaskTrigger -Once -At '10:05' -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Hours 2)).Repetition

# 备用触发: 登录后延迟 10 分钟(开机超过定时时间的补签场景)
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$triggerLogon.Delay = 'PT10M'

# 执行上限 1 小时; 主脚本的 -MaxWaitMinutes 默认 50, 两者需保持 50 < 60
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggerDaily, $triggerLogon -Settings $settings -Principal $principal | Out-Null

Get-ScheduledTask -TaskName $TaskName | Format-List TaskName, State
Get-ScheduledTaskInfo -TaskName $TaskName | Format-List NextRunTime, LastRunTime, LastTaskResult
Write-Host "已注册计划任务 $TaskName (每天 10:05 起每小时重试至 12:05 + 登录后 10 分钟兜底)"
