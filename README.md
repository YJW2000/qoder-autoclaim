# Qoder自动签到脚本（Qoder AutoClaim）

> Qoder自动签到脚本：基于 Windows UI Automation 的 Qoder 桌面端每日积分自动领取工具。  
> 不调用 Qoder 内部 API、不保存账号凭据，通过模拟真实点击完成领取。

[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)](https://learn.microsoft.com/powershell/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## 免责声明

- 本项目**非 Qoder 官方项目**，与 Qoder 没有任何关联。
- 脚本通过 UI 自动化模拟用户操作，Qoder 客户端改版后可能失效。使用前请自行确认 Qoder 服务条款是否允许此类自动化；因使用本脚本产生的任何后果由使用者自行承担。
- 运行时会短暂把 Qoder 窗口切到前台并移动鼠标，建议在无人值守时使用。
- 失败诊断会保存**整块虚拟屏幕截图**，可能包含其他窗口内容。请勿把 `screen-latest.png`、`uia-latest.txt` 等诊断文件直接上传到公开渠道。

## 特性

- 纯 PowerShell + 系统自带 UI Automation，无第三方依赖、无网络请求
- 幂等：只有拿到「已领取」按钮或「领取成功，Credits 已到账」的阳性证据时才写日期标记，当天不会重复领取
- 不误判：权益弹层里既没有「领取」按钮、也没有「已领取」证据时**不写标记**，留给后续重试
- 计划任务每天 10:05 触发，11:05、12:05 各重试一次；登录后 10 分钟再补跑一次
- 失败自动留证：日志、UIA 控件树、屏幕截图
- `-DryRun` 只读检测；`-DumpTree` 导出控件树，方便客户端改版后重新适配

## 工作原理

Qoder 的每日积分入口位于桌面端左下角「打开用户菜单」→「权益中心，有权益待领取」→「权益活动内容」弹层里。**实测领取窗口为每天 10:00（UTC+8）开放**。弹层内的每日卡片只会显示「领取」或「已领取」，领取成功后出现「领取成功，Credits 已到账」。注意：「查看我的用量」面板里没有这个入口，脚本不会去那里找。脚本按以下流程执行：

1. 检查 `%LOCALAPPDATA%\QoderAutoClaim\last-claim.txt` 是否已是当前窗口，是则退出
2. 等待到配置的领取时间（默认 10:05；早于该时间触发且超过等待上限则退出 2）
3. 定位 Qoder 进程；未运行则以 `--force-renderer-accessibility` 启动
4. 还原/激活 Qoder 窗口，注册 UIA 焦点事件，让 Chromium 保持辅助功能树
5. 用 `EnumWindows` 枚举该进程的全部顶层窗口，再用 `TreeWalker` 遍历控件树
6. 用真实鼠标点击左下角「打开用户菜单」，再点击菜单里的「权益中心，有权益待领取」
7. 等待独立 HWND 的「权益活动内容」弹层加载完成
8. 在弹层内点击精确匹配的「领取」按钮（只认 `^领取$`，避免误点「每天领 100 Credits」）
9. 只认完全落在弹层矩形内的「已领取」按钮或「领取成功，Credits 已到账」文案；拿到阳性证据才写标记。没有入口不写标记；结果未知则 exit 3

### 为什么不用 Qoder API

脚本不依赖任何私有接口、Cookie 或登录令牌，只操作已经登录的桌面客户端。代价是依赖 UI 结构，Qoder 改版后可能需要用 `-DumpTree` 重新校准匹配规则。

## 环境要求

- Windows 10 / 11
- **Windows PowerShell 5.1**（使用 `powershell.exe`，不建议用 `pwsh`）
- 已安装并登录 Qoder 桌面端
- 交互式用户会话：计划任务使用 `Interactive` 登录类型，不能作为 Windows 服务运行
- 两个 `.ps1` 文件必须保持 **UTF-8 with BOM**，否则 PowerShell 5.1 会把中文读成乱码，导致控件匹配失效

## 快速开始

```powershell
git clone https://github.com/YJW2000/qoder-autoclaim.git
cd qoder-autoclaim

# 1. 只读检测：不点击、不写标记（仍可能覆盖诊断文件）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Qoder-AutoClaim.ps1 -DryRun

# 2. 导出当前界面控件树，用于排查或适配改版
powershell -NoProfile -ExecutionPolicy Bypass -File .\Qoder-AutoClaim.ps1 -DumpTree

# 3. 手动执行一次正式领取
powershell -NoProfile -ExecutionPolicy Bypass -File .\Qoder-AutoClaim.ps1

# 4. 注册计划任务（通常不需要管理员；如提示拒绝访问，请用管理员 PowerShell）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AutoClaimTask.ps1
```

如果 Qoder 安装在非默认路径：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Qoder-AutoClaim.ps1 -ExePath "D:\Apps\Qoder\Qoder.exe"
```

## 文件说明

| 文件 | 说明 |
|---|---|
| `Qoder-AutoClaim.ps1` | 主脚本：定位窗口、打开用户菜单与权益中心、点击领取、写标记 |
| `Install-AutoClaimTask.ps1` | 注册计划任务 `Qoder-AutoClaim` |
| `run-hidden.vbs` | 供计划任务调用，完全隐藏 PowerShell 窗口 |
| `LICENSE` | MIT 许可证 |

## 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-DryRun` | 关闭 | 只读检测；不点击、不写标记。弹层已打开时会报告将要点击的控件 |
| `-DumpTree` | 关闭 | 导出控件树到 `uia-latest.txt` 后退出 |
| `-MaxWaitMinutes` | `50` | 距领取时间超过该分钟数则退出 2；必须小于计划任务的 1 小时执行上限 |
| `-ExePath` | 空 | 手动指定 `Qoder.exe`，Qoder 未运行且自动发现失败时使用 |

脚本顶部的可调配置：

```powershell
$ClaimHour     = 10   # 本机时区的领取小时
$ClaimMinute   = 5    # 领取分钟；计划任务也按 10:05 注册
$RefreshHour   = 10   # Qoder 每天 10:00 (UTC+8) 刷新
$MenuButtonRegex  = '^打开用户菜单$'
$RightsEntryRegex = '权益中心'
$RightsDialogName = '权益活动内容'
$ClaimRegex       = '^领取$'
$ClaimedRegex     = '已领取|领取成功|Credits 已到账|Claimed|明日再来|明天再来|今日已领'
```

> Qoder 每日领取窗口实测为 **10:00（UTC+8）** 开放。默认计划任务在 **10:05** 首次运行，11:05、12:05 再各重试一次；如果首次运行时活动页尚未刷新，后两轮会补上。若以后开放时间变化，请同时调整 `$ClaimHour`/`$ClaimMinute`、`$RefreshHour`/`$RefreshMinute` 和 `Install-AutoClaimTask.ps1` 中的计划任务时间。

## 计划任务

`Install-AutoClaimTask.ps1` 注册的任务 `Qoder-AutoClaim` 包含：

- 每天 `10:05` 首次触发
- 之后每小时重复一次，持续 2 小时（11:05、12:05），覆盖活动页刷新延迟或首次失败
- 用户登录后延迟 10 分钟补跑一次
- 单次执行上限 1 小时，已在运行时不重复启动
- 使用 `wscript.exe` + `run-hidden.vbs` 隐藏窗口

卸载：

```powershell
Unregister-ScheduledTask -TaskName Qoder-AutoClaim -Confirm:$false
```

## 退出码与状态

| 退出码 | 含义 |
|---|---|
| `0` | 成功、已领取，或没有找到权益入口（**未写标记**，等待下轮重试） |
| `2` | 未到领取时间，且距离开放超过 `-MaxWaitMinutes` |
| `3` | 已找到权益入口/弹层，但领取流程未走通或结果无法确认 |
| `4` | 环境异常：找不到 Qoder、主窗口超时、UIA 辅助功能树元素过少 |

**注意：`exit 0` 不等于一定领取成功。** 判断当天是否领取成功请同时检查：

1. `last-claim.txt` 的内容是否为当天日期
2. `autoclaim.log` 中是否有「检测到已领取文案」或「领取成功」记录

如果没有标记文件，即使任务结果码为 0，也说明状态未被确认，脚本会在下一个整点继续尝试。

## 日志与诊断

所有状态文件位于 `%LOCALAPPDATA%\QoderAutoClaim\`：

| 文件 | 内容 |
|---|---|
| `autoclaim.log` | 追加式运行日志 |
| `last-claim.txt` | 最近一次确认领取成功的日期（`yyyy-MM-dd`） |
| `uia-latest.txt` | 最近一次导出的可交互控件树 |
| `screen-latest.png` | 失败/未确认时的屏幕截图 |

想在同一天手动重跑，可删除 `last-claim.txt` 后再执行脚本。

## 常见问题

**脚本退出 3，日志提示找不到「打开用户菜单」**  
Qoder 可能改版。先用 `-DumpTree` 导出 `uia-latest.txt`，根据实际控件名调整 `$MenuButtonRegex` / `$RightsEntryRegex` / `$RightsDialogName` / `$ClaimRegex`。

**日志提示「没有找到可用的权益入口」**  
说明用户菜单里没有「权益中心」或菜单项没有加载出来。大概率还没到开放时间（实测为 10:00 UTC+8），脚本不会写标记，计划任务会在下一个整点重试。如果整天都如此，请手动打开一次权益中心确认状态，并用 `-DumpTree` 检查菜单项名称是否变化。

**日志提示「权益活动弹层未出现领取或已领取」**  
活动页可能还在加载或改版。脚本会保留 `uia-latest.txt` 和截图，不写标记并退出 3；请手动打开权益中心查看是否出现新的文案，再调整 `$ClaimRegex` / `$ClaimedRegex`。

**退出 4，日志提示 UIA 元素过少**  
确保 Qoder 未最小化，并且是以交互式用户身份运行。脚本会尝试激活窗口；如果仍然失败，可手动启动 Qoder 后再运行。

**脚本没有点中按钮 / 点到了别的窗口**  
脚本在点击前会校验 Qoder 是否在前台，并额外用 `WindowFromPoint` + 窗口 PID 校验点击坐标处确实属于 Qoder；任一检查失败就跳过本轮。请避免在运行时段用其他窗口完全遮挡 Qoder。

**计划任务没有运行**  
检查任务状态与上次结果：

```powershell
Get-ScheduledTask -TaskName Qoder-AutoClaim | Format-List State
Get-ScheduledTaskInfo -TaskName Qoder-AutoClaim | Format-List LastRunTime,LastTaskResult,NextRunTime
```

## 安全与隐私

- 脚本不读取、不保存 Qoder 账号密码或令牌
- 不发起任何网络请求
- 日志可能包含窗口控件名称；截图可能包含屏幕上的其他内容，分享前请自行脱敏
- 所有数据仅保存在本机 `%LOCALAPPDATA%\QoderAutoClaim\`

## 变更记录

### 2026-10-21

- **修正领取入口**：每日积分入口实际位于「打开用户菜单 → 权益中心，有权益待领取 → 权益活动内容 → 领取」，不在「查看我的用量」面板。脚本已改为走正确入口，并避免误点「每天领 100 Credits」。
- **计划任务改为 10:05**：10:00 刷新后 5 分钟首次运行，11:05、12:05 各重试一次（原为 00:05 起 12 小时）。
- **修复扫描返回值**：`Get-AllElements` 直接输出元素，避免 `@()` 只包住一个 `ArrayList`、导致元素总数恒为 1。
- **证据匹配改为矩形完全包含**：聊天区大段文字的中心也可能落在弹层矩形里，现已要求证据控件完全位于弹层内，防止把聊天文本误判为「已领取」。
- **修复等待上限冲突**：`-MaxWaitMinutes` 默认值由 180 改为 50，避免超过计划任务 1 小时的执行上限导致进程被强杀。
- **修复「无入口即写标记」误判**：只有检测到「已领取」或「领取成功，Credits 已到账」才写入 `last-claim.txt`。没有入口时保留诊断信息并退出 0，等待下一个整点重试。
- **去除个人路径**：安装脚本改用 `$PSScriptRoot`，`run-hidden.vbs` 改为接收脚本路径参数，新增 `-ExePath`。
- **点击安全**：点击前同时校验前台窗口 PID 与 `WindowFromPoint` 处的顶层窗口 PID；被其他窗口遮挡时跳过，防止误点。

## License

[MIT](LICENSE)
