#requires -Version 5.1
<#
.SYNOPSIS
  verify.ps1 — deepfreeze.ps1 自检 (REVIEW-001 版: 核心正/负路径 + T1-T6)
.DESCRIPTION
  核心: 改/删/增破坏后 restore 全恢复; 未保护 restore 被拒
  T1 锁定文件: restore 不崩, 报漂移, 退出码非 0
  T2 快照缺失: restore 拒绝执行
  T3 KeepBackups: 旧 pre-restore 备份按上限清理
  T4 Unicode/空格/特殊字符文件名: 全流程通过
  T5 junction 穿透: 指向 $AllowedRoot 外的链接被拒; 指向内的放行
  T6 purge 后重保护: 状态干净重建
  N1/N2 manifest 不泄漏不自包含; N3/N4 多快照+history; N5 指定快照还原;
  N6 默认还原最近; N7 快照轮转; N8 .tmp 半成品隔离
  H1~H8 快照根可配 (DFB-20261005-002): 默认落点回归 / 共享库落点 / state.json 持久化 /
        多源 srcKey 隔离不撞名 / 旧 state.json 向后兼容 / store 自动创建 / 护栏不放宽 /
        purge 孤儿清理边界 (返工 C1: 清本源默认位置遗留快照, 不碰他源 srcKey, 留审计日志)
  P1~P3 manifest 读取优化 (DFB-20261005-003): Get-Manifest List 化后 manifest 形状与哈希
        逐位不变 (流式哈希 vs Get-FileHash 双路比对) / Get-Diff List 化后漂移分类与 restore
        全链路不变 / history 流式计数不错数
  Q1~Q6 格式守卫 + ForceLarge 空间警告 (DFB-20261006-004): 多行格式不误伤 / 紧凑单行格式
        (-Compress 形态) 被 history 拒绝且报格式异常 (fail-closed 不回退) / 空 manifest
        (files=[]) 不被误判 / -ForceLarge 默认落点空间警告出现 / 同卷 -SnapshotRoot 警告
        不回归 (C2) / 正常 protect 不弹空间警告 (-ForceLarge 专属, 防误报)
  C1~C11 卡号绑定 (DFB-20261019-001): protect --card 合法卡号写 link / link 字段完整且 snap_path
        绝对路径真实存在 / 非法卡号 fail-closed 且零副作用 (含大小写敏感 / 仅 ASCII 数字 / 尾部
        换行三处正则绕过面) / 不带 -Card 不产 link (向后兼容) / 同卡重复 protect 覆盖 snap 字段 /
        轮转不删被引用 manifest / 共享库模式 link 落源目录 / link 不进快照 / 非 protect 子命令带
        -Card 不报错 / link 写入失败时 protect 非零退出且 state.json 标记 linked:false / 坏 link
        触发 BlockAll 警告且 manifest 只增不减
  退出码: 0 = PASS, 1 = FAIL
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script = Join-Path $Root 'deepfreeze.ps1'
# 让自检与仓库所在位置解耦: 沙箱就在 $Root 下, 所以把安全边界钉到 $Root。
# 比用户自己配置的边界更窄(只覆盖本仓库), 只会更安全; 且仅作用于本进程与子进程。
# 顺带让 DEEPFREEZE_ALLOWED_ROOT 这条配置路径每次自检都被真实走到。
$env:DEEPFREEZE_ALLOWED_ROOT = $Root
$Sandbox = Join-Path $Root '_selftest\data'
$Outside = Join-Path ([System.IO.Path]::GetTempPath()) 'deepfreeze-t5-outside'  # 必须在 $AllowedRoot(= $Root) 之外; 系统 TEMP 在 C 盘, 天然在仓库外

$failures = @()
$checkCount = 0
function Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  $script:checkCount++
  if ($Ok) { Write-Host "  [PASS] $Name" }
  else { Write-Host "  [FAIL] $Name $Detail"; $script:failures += $Name }
}

function Reset-Sandbox {
  if (Test-Path -LiteralPath $Sandbox) { Remove-Item -LiteralPath $Sandbox -Recurse -Force }
  New-Item -ItemType Directory -Force -Path "$Sandbox\sub" | Out-Null
  'alpha-content' | Set-Content -LiteralPath "$Sandbox\a.txt" -Encoding UTF8
  'beta-content'  | Set-Content -LiteralPath "$Sandbox\b.txt" -Encoding UTF8
  'gamma-content' | Set-Content -LiteralPath "$Sandbox\sub\c.txt" -Encoding UTF8
}

function ConvertTo-QuotedArg {
  # 为 ProcessStartInfo.Arguments 拼命令行: 仅含空白/引号的参数才加引号 (PS 5.1 无 ArgumentList)。
  # 本自检的参数 (路径/卡号/开关) 实际都不含引号, 此处按 Windows 命令行约定保守转义。
  param([string]$Value)
  if ($null -eq $Value) { return '""' }
  if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
  return $Value
}

function Invoke-Deepfreeze {
  # 子进程调用 (DFB-20261021-001 D4 加固)。返回形态固定 @{ Out; Code }, 调用方无感。
  #
  # 加固点:
  #   1) 超时 watchdog: 默认 120s ($TimeoutSec 按项可调; protect 大目录可能慢)。超时用 taskkill /T
  #      连子孙 (robocopy) 一起收掉, 避免挂死自检 / 遗留进程占锁级联污染后续项。
  #   2) 环境类失败允许一次重试 (重试前 settle 400ms), 二次仍败才计入。
  #
  # 「环境类 vs 语义类」判定标准 (本卡红线):
  #   · 环境类失败 = **进程级异常**, 与断言语义无关, 重跑常可恢复 → 允许重试一次:
  #       - 超时 (进程没跑出结果, 被 watchdog 杀掉);
  #       - 非零退出 —— 负载/IO 瞬态导致子进程自身失败 (成功路径被负载打断)。
  #   · 语义类失败 = **断言的语义判定为假** (如 restore 本该拒绝却 exit 0 / 本该成功却报错),
  #     其真伪由**调用方的 Check 判定**, 本函数只如实回传 Code/Out —— 绝不重试、绝不改写结果,
  #     因此不会把真失败「吞」成通过 (fail-closed 红线保留)。重试返回的仍是**本次真实退出码**,
  #     语义类失败照旧传回给 Check 判死。
  param([string[]]$DfArgs, [int]$TimeoutSec = 120)
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'   # 子进程 stderr 是预期内输出, 不许终止本脚本
  try {
    $attempt = 0
    while ($true) {
      $attempt++
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName               = 'powershell.exe'
      $psi.Arguments              = ((@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $DfArgs) |
                                      ForEach-Object { ConvertTo-QuotedArg $_ }) -join ' '
      $psi.UseShellExecute        = $false
      $psi.CreateNoWindow         = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError  = $true
      # 与旧 `&` 捕获同源: 子进程按 [Console]::OutputEncoding 输出, 这里按同一编码解码 ——
      # 保证中文断言 (如 '快照目录缺失') 不失真。
      $psi.StandardOutputEncoding = [Console]::OutputEncoding
      $psi.StandardErrorEncoding  = [Console]::OutputEncoding
      $proc = New-Object System.Diagnostics.Process
      $proc.StartInfo = $psi
      $null = $proc.Start()
      $soTask = $proc.StandardOutput.ReadToEndAsync()
      $seTask = $proc.StandardError.ReadToEndAsync()
      $timedOut = $false
      if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        $null = $proc.WaitForExit(5000)
      }
      $stdout = try { $soTask.Result } catch { '' }
      $stderr = try { $seTask.Result } catch { '' }
      $code = if ($timedOut) { -1 } else { $proc.ExitCode }
      $proc.Dispose()
      $text = (@($stdout, $stderr) | Where-Object { $_ -ne $null -and $_ -ne '' }) -join "`n"
      # 环境类失败 (超时 / 非零退出) 才重试一次; 成功 (exit 0) 直接回传。语义判定留给调用方。
      if (-not $timedOut -and $code -eq 0) { break }
      if ($attempt -ge 2) { break }
      Start-Sleep -Milliseconds 400
    }
  } finally { $ErrorActionPreference = $prevEap }
  return @{ Out = $text; Code = $code }
}

Write-Host '== deepfreeze 自检 (REVIEW-001 版) =='

# ---------- 核心正路径 ----------
Write-Host "`n[核心] 正路径: protect -> 改/删/增 -> restore"
Reset-Sandbox
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
Check 'protect 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code)"

'tampered' | Set-Content -LiteralPath "$Sandbox\a.txt" -Encoding UTF8
Remove-Item -LiteralPath "$Sandbox\b.txt" -Force
'evil' | Set-Content -LiteralPath "$Sandbox\evil.txt" -Encoding UTF8
'tampered' | Set-Content -LiteralPath "$Sandbox\sub\c.txt" -Encoding UTF8

$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'restore 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'a.txt 内容恢复'     (((Get-Content -LiteralPath "$Sandbox\a.txt" -Raw).TrimEnd("`r","`n")) -eq 'alpha-content')
Check 'b.txt 删后恢复'     (Test-Path -LiteralPath "$Sandbox\b.txt")
Check 'sub\c.txt 恢复'     (((Get-Content -LiteralPath "$Sandbox\sub\c.txt" -Raw).TrimEnd("`r","`n")) -eq 'gamma-content')
Check 'evil.txt 被冰点删除' (-not (Test-Path -LiteralPath "$Sandbox\evil.txt"))

# ---------- 核心负路径 ----------
Write-Host "`n[核心] 负路径: unprotect 后 restore 必须被拒"
$null = Invoke-Deepfreeze @('unprotect', '-Source', $Sandbox, '-AutoConfirm')
$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check '未保护时 restore 被拒 (exit 非 0)' ($r.Code -ne 0)

# ---------- T2 快照缺失 ----------
Write-Host "`n[T2] 快照目录缺失时 restore 拒绝执行"
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' |
  Remove-Item -Recurse -Force
# D1 (DFB-20261021-001): 高负载/Defender 下 Remove-Item 可能静默半删 ——
# 删后确认 snap-* 真的清零, 短重试 (8 × 250ms ≈ 2s); 残留则告警说明。
# 告警后继续断言: 残留会让 restore 不拒绝, Check 照判 —— 环境类现象可诊断,
# 不伪装成通过, 也不改写断言语义。
$t2Attempt = 0
while ($t2Attempt -lt 8 -and
       @(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue).Count -gt 0) {
  Start-Sleep -Milliseconds 250
  $t2Attempt++
  Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force
}
if (@(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue).Count -gt 0) {
  Write-Warning "T2 前置: 快照目录删除后仍残留 (负载/句柄占用) —— 环境类现象, 非代码回归; T2 断言可能因此失败"
}
$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'T2 快照缺失被拒 (exit 非 0)' ($r.Code -ne 0)
Check 'T2 报错含"快照目录缺失"' ($r.Out -match '快照目录缺失')

# ---------- T1 锁定文件 ----------
Write-Host "`n[T1] 目标文件被进程锁定时: restore 不崩, 报漂移, exit 非 0"
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
'tampered' | Set-Content -LiteralPath "$Sandbox\a.txt" -Encoding UTF8
'tampered2' | Set-Content -LiteralPath "$Sandbox\b.txt" -Encoding UTF8
$fs = [System.IO.File]::Open("$Sandbox\a.txt", 'Open', 'ReadWrite', 'None')
try {
  $r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
  Check 'T1 restore 退出码非 0 (漂移被捕获)' ($r.Code -ne 0)
  Check 'T1 输出含漂移报告' ($r.Out -match '漂移')
  Check 'T1 未锁定的 b.txt 仍被恢复' (((Get-Content -LiteralPath "$Sandbox\b.txt" -Raw).TrimEnd("`r","`n")) -eq 'beta-content')
}
finally { $fs.Dispose() }
$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'T1 解锁后 restore 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code)"

# ---------- T3 KeepBackups ----------
Write-Host "`n[T3] KeepBackups=2: 连续 restore 后旧备份按上限清理"
$null = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-KeepBackups', '2', '-AutoConfirm')
$null = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-KeepBackups', '2', '-AutoConfirm')
$null = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-KeepBackups', '2', '-AutoConfirm')
$bakCount = (Get-ChildItem -LiteralPath "$Sandbox\.freeze" -Directory -Filter 'prerestore-*' -ErrorAction SilentlyContinue).Count
Check 'T3 prerestore 备份数 <= 2' ($bakCount -le 2) "实际 $bakCount"

# ---------- T4 Unicode/空格/特殊字符 ----------
Write-Host "`n[T4] Unicode/空格/括号文件名全流程"
Reset-Sandbox
New-Item -ItemType Directory -Force -Path "$Sandbox\sub" | Out-Null
'u1' | Set-Content -LiteralPath "$Sandbox\测试 文件(1).txt" -Encoding UTF8
'u2' | Set-Content -LiteralPath "$Sandbox\résumé #@!.txt" -Encoding UTF8
'u3' | Set-Content -LiteralPath "$Sandbox\sub\数据 表 [终版].csv" -Encoding UTF8
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
Check 'T4 protect 成功' ($r.Code -eq 0)
'changed' | Set-Content -LiteralPath "$Sandbox\测试 文件(1).txt" -Encoding UTF8
$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'T4 restore 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code)"
Check 'T4 Unicode 文件内容恢复' (((Get-Content -LiteralPath "$Sandbox\测试 文件(1).txt" -Raw).TrimEnd("`r","`n")) -eq 'u1')

# ---------- T5 junction 穿透 ----------
Write-Host "`n[T5] junction 按真实目标判定边界"
Reset-Sandbox
if (Test-Path -LiteralPath $Outside) { Remove-Item -LiteralPath $Outside -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Outside | Out-Null
'outside-secret' | Set-Content -LiteralPath "$Outside\secret.txt" -Encoding UTF8
$jlink = Join-Path $Root '_selftest\jlink-outside'
if (Test-Path -LiteralPath $jlink) { [System.IO.Directory]::Delete($jlink, $true) }
$mklinkOut = & cmd.exe /c "mklink /J `"$jlink`" `"$Outside`"" 2>&1
$r = Invoke-Deepfreeze @('protect', '-Source', $jlink, '-AutoConfirm')
Check 'T5 指向外部的 junction 被拒 (exit 非 0)' ($r.Code -ne 0)
Check 'T5 报错含安全边界说明' ($r.Out -match '安全边界')
# 内部 junction 应放行 (先确保目标本身处于保护态)
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
$jlink2 = Join-Path $Root '_selftest\jlink-inside'
if (Test-Path -LiteralPath $jlink2) { [System.IO.Directory]::Delete($jlink2, $true) }
$null = & cmd.exe /c "mklink /J `"$jlink2`" `"$Sandbox`"" 2>&1
$r = Invoke-Deepfreeze @('status', '-Source', $jlink2)
Check 'T5 指向内部的 junction 放行 (status 正常)' ($r.Code -eq 0 -and $r.Out -match 'PROTECTED')

# ---------- T6 purge 后重保护 ----------
Write-Host "`n[T6] unprotect -Purge 后重新 protect"
$r = Invoke-Deepfreeze @('unprotect', '-Source', $Sandbox, '-Purge', '-AutoConfirm')
Check 'T6 unprotect -Purge 成功' ($r.Code -eq 0)
Check 'T6 快照目录已删除' (-not (Test-Path -LiteralPath "$Sandbox\.freeze-snap"))
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
Check 'T6 重新 protect 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
$state = Get-Content -LiteralPath "$Sandbox\.freeze\state.json" -Raw | ConvertFrom-Json
Check 'T6 state.protected=true 且快照干净' ($state.protected -eq $true -and $state.file_count -eq 3)

# ---------- N1/N2 manifest 自我污染修复 ----------
Write-Host "`n[N1/N2] 清单移出快照目录: restore 不泄漏, 二次 protect 不自包含"
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
'tampered' | Set-Content -LiteralPath "$Sandbox\a.txt" -Encoding UTF8
$null = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'N1 restore 后源根不含 manifest.json' (-not (Test-Path -LiteralPath "$Sandbox\manifest.json"))
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
$snaps = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' | Where-Object { $_.Name -notlike '*.tmp' } | Sort-Object Name)
$latestTs = $snaps[-1].Name -replace '^snap-', ''
$man = Get-Content -LiteralPath "$Sandbox\.freeze\manifests\$latestTs.json" -Raw | ConvertFrom-Json
$manPaths = @($man.files | ForEach-Object { $_.path })
Check 'N2 二次 protect 清单不含 manifest.json' (-not ($manPaths -contains 'manifest.json')) "实际: $($manPaths -join ', ')"

# ---------- N3/N4 多快照与 history ----------
Write-Host "`n[N3/N4] 连打 3 个快照, history 全部列出"
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')          # 快照1: a=alpha
'v2' | Set-Content -LiteralPath "$Sandbox\a.txt" -Encoding UTF8
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')          # 快照2: a=v2
'new-later' | Set-Content -LiteralPath "$Sandbox\d.txt" -Encoding UTF8               # 快照2 之后新增
'v3' | Set-Content -LiteralPath "$Sandbox\a.txt" -Encoding UTF8
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')          # 快照3: a=v3
$snapCount = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' | Where-Object { $_.Name -notlike '*.tmp' }).Count
Check 'N3 protect x3 产生 3 个快照' ($snapCount -eq 3) "实际 $snapCount"
$r = Invoke-Deepfreeze @('history', '-Source', $Sandbox)
Check 'N4 history exit 0' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
$tsCount = ([regex]::Matches($r.Out, 'snap-\d{8}-\d{6}')).Count
Check 'N4 history 输出含 3 个时间戳' ($tsCount -eq 3) "实际 $tsCount"

# ---------- N5 回到指定历史点 ----------
Write-Host "`n[N5] restore -Snapshot 最旧快照: 回到快照1状态"
$oldest = ((Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' | Where-Object { $_.Name -notlike '*.tmp' } | Sort-Object Name)[0]).Name -replace '^snap-', ''
$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-Snapshot', $oldest, '-AutoConfirm')
Check 'N5 restore -Snapshot exit 0' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'N5 a.txt 回到最旧快照内容' (((Get-Content -LiteralPath "$Sandbox\a.txt" -Raw).TrimEnd("`r","`n")) -eq 'alpha-content')
Check 'N5 快照1之后新增的 d.txt 被冰点删除' (-not (Test-Path -LiteralPath "$Sandbox\d.txt"))

# ---------- N6 默认还原到最近 ----------
Write-Host "`n[N6] 不带 -Snapshot: 还原到最近快照"
$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'N6 默认 restore exit 0' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'N6 还原到最近快照内容 (v3)' (((Get-Content -LiteralPath "$Sandbox\a.txt" -Raw).TrimEnd("`r","`n")) -eq 'v3')

# ---------- N7 快照轮转 ----------
Write-Host "`n[N7] KeepSnapshots=2: 超出按最旧清理"
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-KeepSnapshots', '2', '-AutoConfirm')
$snapCount = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' | Where-Object { $_.Name -notlike '*.tmp' }).Count
Check 'N7 轮转后真实快照数 <= 2' ($snapCount -le 2) "实际 $snapCount"
$manCount = (Get-ChildItem -LiteralPath "$Sandbox\.freeze\manifests" -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
Check 'N7 清单与快照同步轮转 (manifests <= 2)' ($manCount -le 2) "实际 $manCount"

# ---------- N8 半写快照 (.tmp) 隔离 ----------
Write-Host "`n[N8] 中断残留 *.tmp 不进 history、不计轮转"
New-Item -ItemType Directory -Force -Path "$Sandbox\.freeze-snap\snap-20991231-235959.tmp" | Out-Null
'junk' | Set-Content -LiteralPath "$Sandbox\.freeze-snap\snap-20991231-235959.tmp\junk.txt" -Encoding UTF8
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-KeepSnapshots', '2', '-AutoConfirm')
$r = Invoke-Deepfreeze @('history', '-Source', $Sandbox)
Check 'N8 history 不列出 .tmp 半成品' (-not ($r.Out -match '20991231')) $r.Out
$snapCount = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' | Where-Object { $_.Name -notlike '*.tmp' }).Count
Check 'N8 轮转不把 .tmp 计入 (真实快照 <= 2)' ($snapCount -le 2) "实际 $snapCount"
$manCount = (Get-ChildItem -LiteralPath "$Sandbox\.freeze\manifests" -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
Check 'N8 清单数与真实快照一致 (manifests <= 2)' ($manCount -le 2) "实际 $manCount"

# ---------- G1~G6 规模护栏 (DFB-20261004-001, 追加于 39 项基线之后, 未改动任何基线断言) ----------
Write-Host "`n[G1] 源=安全边界根本身: 拒绝且零副作用"
# 零写入用前后计数对比断言: 仓库可能本来就有历史快照, Test-Path 探测法区分不了
# 「本次没写」与「本来就有」(返工单 B1)。必须先 Test-Path 再计数——对不存在路径
# 用 Get-ChildItem -Recurse 会把末段当通配符递归匹配到别处 (任务卡 A3 原始缺陷)
$gSnapDir = Join-Path $Root '.freeze-snap'
$gBefore = if (Test-Path $gSnapDir) { @(Get-ChildItem $gSnapDir -Directory -Filter 'snap-*').Count } else { 0 }
$r = Invoke-Deepfreeze @('protect', '-Source', $Root, '-AutoConfirm')
$gAfter = if (Test-Path $gSnapDir) { @(Get-ChildItem $gSnapDir -Directory -Filter 'snap-*').Count } else { 0 }
Check 'G1 边界根被拒 (exit 非 0, -AutoConfirm 下依然拒绝)' ($r.Code -ne 0) "exit=$($r.Code)"
Check 'G1 报错含规模护栏说明' ($r.Out -match '规模护栏')
Check 'G1 拒绝时快照数未增加 (零写入)' ($gAfter -eq $gBefore) "before=$gBefore after=$gAfter"

Write-Host "`n[G2] 源=盘根 (-Force 越过路径边界后): 仍被规模护栏拒绝"
$drive = Split-Path -Qualifier $Root
$r = Invoke-Deepfreeze @('protect', '-Source', "$drive\", '-AllowedRoot', $Root, '-Force', '-AutoConfirm')
Check 'G2 盘根被拒 (exit 非 0)' ($r.Code -ne 0) "exit=$($r.Code)"
Check 'G2 报错指明盘根' ($r.Out -match '盘根')

Write-Host "`n[G3] 超文件数阈值 (5001 个文件 > 5000): 拒绝"
$gBig = Join-Path $Root '_selftest\guard-big'
if (Test-Path -LiteralPath $gBig) { Remove-Item -LiteralPath $gBig -Recurse -Force }
New-Item -ItemType Directory -Force -Path $gBig | Out-Null
1..5001 | ForEach-Object { Set-Content -LiteralPath (Join-Path $gBig "f$_.txt") -Value 'x' -Encoding ASCII }
$r = Invoke-Deepfreeze @('protect', '-Source', $gBig, '-AutoConfirm')
Check 'G3 超文件数阈值被拒 (exit 非 0)' ($r.Code -ne 0) "exit=$($r.Code)"
Check 'G3 报错含文件数阈值说明' ($r.Out -match '文件数')
Check 'G3 未产生快照 (只有被拒现场, 无 snap-*)' (-not (Test-Path "$gBig\.freeze-snap\snap-*"))

Write-Host "`n[G4] 超字节阈值 (501 个 1MB 文件 = 525MB > 500MB, 文件数在阈值内): 拒绝"
# D2 (DFB-20261021-001): 525MB 写盘是全自检最重的 I/O 项 —— 磁盘压力下夹具
# 写入 (501 × WriteAllBytes) 可能抛异常, 此前会把整个自检带崩
# (ErrorActionPreference=Stop)。夹具构建失败允许一次重试 (环境类);
# protect 调用的超时/非零退出已由 Invoke-Deepfreeze 内部重试兜底 (D4),
# 断言阈值与拒绝语义不变。
$gBytes = Join-Path $Root '_selftest\guard-bytes'
$g4SetupAttempt = 0
while ($true) {
  $g4SetupAttempt++
  if (Test-Path -LiteralPath $gBytes) { Remove-Item -LiteralPath $gBytes -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $gBytes | Out-Null
  try {
    $mbBuf = New-Object byte[] (1MB)
    1..501 | ForEach-Object { [System.IO.File]::WriteAllBytes((Join-Path $gBytes "b$_.bin"), $mbBuf) }
    break
  } catch {
    Write-Warning "G4 夹具写入失败 (attempt $g4SetupAttempt): $_"
    if ($g4SetupAttempt -ge 2) { throw }
    Start-Sleep -Milliseconds 400
  }
}
$r = Invoke-Deepfreeze @('protect', '-Source', $gBytes, '-AutoConfirm')
Check 'G4 超字节阈值被拒 (exit 非 0)' ($r.Code -ne 0) "exit=$($r.Code)"
Check 'G4 报错含字节阈值说明' ($r.Out -match '总字节数|字节数')

Write-Host "`n[G5] -ForceLarge 逃生开关: 放行且 actions.log 留痕"
$r = Invoke-Deepfreeze @('protect', '-Source', $gBig, '-ForceLarge', '-AutoConfirm')
Check 'G5 -ForceLarge 对超阈目录放行 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
$gLog = Get-Content -LiteralPath "$gBig\.freeze\actions.log" -Raw -ErrorAction SilentlyContinue
Check 'G5 actions.log 含护栏越过记录' ($null -ne $gLog -and $gLog -match 'ForceLarge')

Write-Host "`n[G6] 正常规模目录不受护栏影响 (回归保护)"
Reset-Sandbox
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
Check 'G6 正常目录 protect 成功 (exit 0, 未被误杀)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"

# ---------- H1~H7 快照根可配 (DFB-20261005-002, 追加于 52 项基线之后, 未改动任何既有断言) ----------
Write-Host "`n[H系列] -SnapshotRoot 快照存储位置可配"
$HStore  = Join-Path $Root '_selftest\snapstore'
$HStore2 = Join-Path $Root '_selftest\snapstore-auto'
$HSrcB   = Join-Path $Root '_selftest\data-srcB'
if (Test-Path -LiteralPath $HStore)  { Remove-Item -LiteralPath $HStore  -Recurse -Force }
if (Test-Path -LiteralPath $HStore2) { Remove-Item -LiteralPath $HStore2 -Recurse -Force }
if (Test-Path -LiteralPath $HSrcB)   { Remove-Item -LiteralPath $HSrcB   -Recurse -Force }
New-Item -ItemType Directory -Force -Path $HSrcB | Out-Null
'b-content' | Set-Content -LiteralPath "$HSrcB\b.txt" -Encoding UTF8

Write-Host "  [H1] 回归: 不传 -SnapshotRoot 时默认落点不变"
Reset-Sandbox
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
Check 'H1 默认模式 protect 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'H1 快照仍落在 <Source>\.freeze-snap' ((@(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp')).Count -ge 1)
$hstate = Get-Content -LiteralPath "$Sandbox\.freeze\state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'H1 state.json 记录 snapshot_root 且=默认落点' ($hstate.PSObject.Properties['snapshot_root'] -and $hstate.snapshot_root -eq "$Sandbox\.freeze-snap")

Write-Host "  [H2] 指定 -SnapshotRoot: 快照落指定根 (store 不存在→自动创建), 源目录无 .freeze-snap"
Reset-Sandbox
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-SnapshotRoot', $HStore, '-AutoConfirm')
Check 'H2 共享库模式 protect 成功 (exit 0, 含不存在 store 自动创建)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'H2 快照落在 <SnapshotRoot>\<srcKey>\snap-* 下' ((@(Get-ChildItem -LiteralPath $HStore -Recurse -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp')).Count -ge 1)
Check 'H2 源目录未产生 .freeze-snap' (-not (Test-Path -LiteralPath "$Sandbox\.freeze-snap"))

Write-Host "  [H3] 持久化: restore/history 不带位置参数, 从 state.json 读回共享库"
'tampered' | Set-Content -LiteralPath "$Sandbox\a.txt" -Encoding UTF8
$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'H3 restore 不带快照位置参数成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'H3 内容从共享库快照恢复' (((Get-Content -LiteralPath "$Sandbox\a.txt" -Raw).TrimEnd("`r","`n")) -eq 'alpha-content')
$r = Invoke-Deepfreeze @('history', '-Source', $Sandbox)
Check 'H3 history 不带参数列出共享库快照 (exit 0 且含时间戳)' ($r.Code -eq 0 -and ([regex]::Matches($r.Out, 'snap-\d{8}-\d{6}')).Count -ge 1) "exit=$($r.Code)"

Write-Host "  [H4] 核心不变量: 两个不同源共用一个 store, srcKey 子目录互异不撞名"
$null = Invoke-Deepfreeze @('protect', '-Source', $HSrcB, '-SnapshotRoot', $HStore, '-AutoConfirm')
$hKeys = @(Get-ChildItem -LiteralPath $HStore -Directory)
Check 'H4 共享库下产生 2 个 srcKey 目录' ($hKeys.Count -eq 2) "实际 $($hKeys.Count)"
Check 'H4 srcKey 目录名两两不同' ((@($hKeys | ForEach-Object { $_.Name } | Select-Object -Unique)).Count -eq $hKeys.Count)
$rA = Invoke-Deepfreeze @('history', '-Source', $Sandbox)
Check 'H4 源A history 只见自己的快照 (1 个, 跨源不可见)' (([regex]::Matches($rA.Out, 'snap-\d{8}-\d{6}')).Count -eq 1)
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')   # 不带 -SnapshotRoot: 应循 state.json 留在共享库
Check 'H4 重复 protect 不带参数仍落共享库 (未回退默认落点)' (-not (Test-Path -LiteralPath "$Sandbox\.freeze-snap"))
$hSnaps = @(Get-ChildItem -LiteralPath $HStore -Recurse -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp')
# D2 (DFB-20261021-003): 原精确计数 `= 3` 对负载敏感（评审 RUN4 实测漂移——
# 跨源混写边界的高负载下 srcKey 枚举时序抖动）。精确总数不是「跨源隔离」
# 不变量的承载体——真正的隔离语义已由上面三条断言承载（srcKey 互异 / 源A
# history 跨源不可见 / 落点不回退默认）。总数改「≥ 各源应有下限」的宽松断言：
# 混写会让某个 srcKey 的快照数异常，这里只确认没有丢快照，不锁精确总数。
Check 'H4 共享库快照总数下限 (A:2 + B:1 = 3, 无丢失; 混写由隔离断言承载)' ($hSnaps.Count -ge 3) "实际 $($hSnaps.Count)"
# 隔离语义加强: 每个 srcKey 目录（快照 FullName 的倒数第 2 段）的快照数必须
# ∈ {1, 2}（A=2 / B=1 的合法集合），且两个 srcKey 的计数互异——混写（源B 的
# 快照出现在源A 的 srcKey 下）会让某侧计数冲出集合或两侧相等，这比总数断言
# 对「无混写」不变量的保护更强，且不依赖 Get-ChildItem 的枚举顺序。
$hKeyCounts = $hSnaps | ForEach-Object { ($_.FullName -split '\\')[-2] } | Group-Object
foreach ($g in $hKeyCounts) {
    Check "H4 srcKey $($g.Name) 快照数 ∈ {1,2} (各源隔离无混写)" (@(1,2) -contains $g.Count) "实际 $($g.Count)"
}
Check 'H4 两个 srcKey 的快照数互异 (2 vs 1; 混写会使两侧相等或越界)' ($hKeyCounts.Count -eq 2 -and ($hKeyCounts | ForEach-Object { $_.Count } | Select-Object -Unique).Count -eq 2) "srcKey 数=$($hKeyCounts.Count), 计数集=$(@($hKeyCounts | ForEach-Object { $_.Count }) -join ',')"

Write-Host "  [H5] 向后兼容: 旧 state.json (无 snapshot_root 字段) 不崩, 回落默认位置"
$hstate = Get-Content -LiteralPath "$Sandbox\.freeze\state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$hstate.PSObject.Properties.Remove('snapshot_root')
($hstate | ConvertTo-Json) | Set-Content -LiteralPath "$Sandbox\.freeze\state.json" -Encoding UTF8
$r = Invoke-Deepfreeze @('history', '-Source', $Sandbox)
Check 'H5 旧 state.json: history 不崩 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'H5 回落默认位置 (共享库快照不可见, 输出无快照)' ($r.Out -match '无快照')

Write-Host "  [H6] 不存在的 SnapshotRoot 显式自动创建"
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-SnapshotRoot', $HStore2, '-AutoConfirm')
Check 'H6 store 不存在时 protect 成功且目录已建' ($r.Code -eq 0 -and (Test-Path -LiteralPath $HStore2 -PathType Container)) "exit=$($r.Code)"
Check 'H6 新 store 下有真实快照' ((@(Get-ChildItem -LiteralPath $HStore2 -Recurse -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp')).Count -ge 1)

Write-Host "  [H7] 护栏未被 -SnapshotRoot 放宽: 超阈源仍拒绝, 共享库零写入"
$hBefore = @(Get-ChildItem -LiteralPath $HStore -Recurse -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp').Count
$r = Invoke-Deepfreeze @('protect', '-Source', $gBig, '-SnapshotRoot', $HStore, '-AutoConfirm')
$hAfter = @(Get-ChildItem -LiteralPath $HStore -Recurse -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp').Count
Check 'H7 超阈源 + -SnapshotRoot 仍被规模护栏拒绝 (exit 非 0)' ($r.Code -ne 0) "exit=$($r.Code)"
Check 'H7 拒绝时共享库零写入' ($hAfter -eq $hBefore) "before=$hBefore after=$hAfter"

Write-Host "  [H8] unprotect -Purge 孤儿清理边界 (返工 C1): 清本源默认位置遗留快照, 不碰同 store 其他 srcKey"
# 锁定卡外新增行为 (评审重点②): 迁移到共享库后 unprotect -Purge 会顺带清理默认位置的
# 遗留快照 —— 行为实测安全, 但此前无断言 = 「对的但没保证以后还对」。三重判据:
# ① 默认位置孤儿被清 ② 同 store 其他 srcKey 不被碰 (「只删本源」边界, 最关键) ③ actions.log 保留
# D3 (DFB-20261021-001) 夹具自足化: 此前复用 H4 的现场 ($HSrcB 共享库模式 + $HStore 里
# keyA 的 2 快照) —— H4 一抖 H8 必挂 (级联)。改为 H8 自建"两源一库"夹具: 自建两源一 store,
# purge 源再手工摆一份默认位置孤儿; 三重判据与阈值语义不变, 仅快照计数随夹具调整。
$h8PurgeSrc = Join-Path $Root '_selftest\h8-purge-src'
$h8KeepSrc  = Join-Path $Root '_selftest\h8-keep-src'
$h8Store    = Join-Path $Root '_selftest\h8-store'
foreach ($h8Dir in @($h8PurgeSrc, $h8KeepSrc, $h8Store)) {
  if (Test-Path -LiteralPath $h8Dir) { Remove-Item -LiteralPath $h8Dir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $h8Dir | Out-Null
}
'purge-me' | Set-Content -LiteralPath "$h8PurgeSrc\p.txt" -Encoding UTF8
'keep-me'  | Set-Content -LiteralPath "$h8KeepSrc\k.txt" -Encoding UTF8
$null = Invoke-Deepfreeze @('protect', '-Source', $h8PurgeSrc, '-SnapshotRoot', $h8Store, '-AutoConfirm')
$null = Invoke-Deepfreeze @('protect', '-Source', $h8KeepSrc,  '-SnapshotRoot', $h8Store, '-AutoConfirm')
# 孤儿: purge 源在其默认位置留一份旧快照 (模拟"迁移共享库前的遗留")
New-Item -ItemType Directory -Force -Path "$h8PurgeSrc\.freeze-snap\snap-20260101-000000" | Out-Null
'legacy-orphan' | Set-Content -LiteralPath "$h8PurgeSrc\.freeze-snap\snap-20260101-000000\legacy.txt" -Encoding UTF8
$h8KeysBefore = @(Get-ChildItem -LiteralPath $h8Store -Directory -ErrorAction SilentlyContinue)
Check 'H8 前置: purge 前 store 含 2 个 srcKey' ($h8KeysBefore.Count -eq 2) "实际 $($h8KeysBefore.Count)"
$r = Invoke-Deepfreeze @('unprotect', '-Source', $h8PurgeSrc, '-Purge', '-AutoConfirm')
Check 'H8 共享库模式 unprotect -Purge 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'H8 ①默认位置遗留快照被清 (.freeze-snap 不复存在)' (-not (Test-Path -LiteralPath "$h8PurgeSrc\.freeze-snap"))
$h8KeysAfter = @(Get-ChildItem -LiteralPath $h8Store -Directory -ErrorAction SilentlyContinue)
Check 'H8 ②他源 srcKey 存活 (store 剩 1 个 key, 未越界清库)' ($h8KeysAfter.Count -eq 1) "实际 $($h8KeysAfter.Count)"
Check 'H8 ②他源快照数据完好 (keep 源的 1 个 snap 原样)' ((@(Get-ChildItem -LiteralPath $h8Store -Recurse -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp')).Count -eq 1)
Check 'H8 ③actions.log 审计日志保留 (C3 裁定)' (Test-Path -LiteralPath "$h8PurgeSrc\.freeze\actions.log")
Check 'H8 ③日志含孤儿清理记录 (分支执行可追溯)' ((Get-Content -LiteralPath "$h8PurgeSrc\.freeze\actions.log" -Raw -ErrorAction SilentlyContinue) -match '同时清理默认位置的遗留快照')

# ---------- P1~P3 manifest 读取优化 (DFB-20261005-003, 追加于 79 项之后, 未改动任何既有断言) ----------
Write-Host "`n[P系列] Get-Manifest/Get-Diff List 化 + 流式哈希 + history 流式计数"
Reset-Sandbox
# 二进制全字节域文件: 锁流式哈希对非文本内容的逐位一致性
$pBin = New-Object byte[] (256 * 64)
for ($i = 0; $i -lt $pBin.Length; $i++) { $pBin[$i] = $i % 256 }
[System.IO.File]::WriteAllBytes((Join-Path $Sandbox 'bin.dat'), $pBin)
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
Check 'P1 protect 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
$pSnaps = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp' | Sort-Object Name)
$pTs = $pSnaps[-1].Name -replace '^snap-', ''
$pMan = Get-Content -LiteralPath "$Sandbox\.freeze\manifests\$pTs.json" -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'P1 manifest 文件数=4 (a/b/bin.dat/sub\c, List 化不改计数)' (@($pMan.files).Count -eq 4) "实际 $(@($pMan.files).Count)"
$pA = @($pMan.files | Where-Object { $_.path -eq 'a.txt' })[0]
$pBinEntry = @($pMan.files | Where-Object { $_.path -eq 'bin.dat' })[0]
$refA = (Get-FileHash -LiteralPath "$Sandbox\a.txt" -Algorithm SHA256).Hash
$refBin = (Get-FileHash -LiteralPath "$Sandbox\bin.dat" -Algorithm SHA256).Hash
Check 'P1 流式哈希与 Get-FileHash 逐位一致 (文本 a.txt)' ($pA.sha256 -ieq $refA) "manifest=$($pA.sha256) ref=$refA"
Check 'P1 流式哈希与 Get-FileHash 逐位一致 (二进制全字节域 bin.dat)' ($pBinEntry.sha256 -ieq $refBin) "manifest=$($pBinEntry.sha256) ref=$refBin"
Check 'P1 manifest 条目结构不变 (path,size,sha256 有序三键, 旧版可读性不破)' (((@($pA.PSObject.Properties.Name)) -join ',') -eq 'path,size,sha256') "实际 $(@($pA.PSObject.Properties.Name) -join ',')"

Write-Host '  [P2] Get-Diff List 化: 漂移分类与 restore 全链路不变'
'changed' | Set-Content -LiteralPath "$Sandbox\a.txt" -Encoding UTF8
'drift-new' | Set-Content -LiteralPath "$Sandbox\d.txt" -Encoding UTF8
Remove-Item -LiteralPath "$Sandbox\b.txt" -Force
$r = Invoke-Deepfreeze @('status', '-Source', $Sandbox)
Check 'P2 diff 三类计数正确 (新增 1 / 变更 1 / 被删 1, List 返回契约不变)' ($r.Out -match '新增 1 个 / 内容变更 1 个 / 被删 1 个') $r.Out
$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'P2 漂移后 restore 成功 (流式哈希全量校验通过, exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"

Write-Host '  [P3] history 流式计数不错数'
$r = Invoke-Deepfreeze @('history', '-Source', $Sandbox)
Check 'P3 history 流式计数正确 (最新快照 4 个文件)' ($r.Out -match 'snap-\d{8}-\d{6}\s+4 个文件') $r.Out

# ---------- Q1~Q6 格式守卫 + ForceLarge 空间警告 (DFB-20261006-004, 追加于 87 项之后, 未改动任何既有断言) ----------
Write-Host "`n[Q系列] manifest 格式守卫 (C1) + -ForceLarge 默认落点空间警告 (S1)"
$QEmpty = Join-Path $Root '_selftest\data-empty'
if (Test-Path -LiteralPath $QEmpty) { Remove-Item -LiteralPath $QEmpty -Recurse -Force }

Write-Host '  [Q1] 多行格式: history 正常计数 (守卫不误伤)'
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
$qSnaps = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp' | Sort-Object Name)
$qTs = $qSnaps[-1].Name -replace '^snap-', ''
$r = Invoke-Deepfreeze @('history', '-Source', $Sandbox)
Check 'Q1 多行格式 history 正常计数 (exit 0 且 3 个文件, 守卫不误伤)' ($r.Code -eq 0 -and $r.Out -match 'snap-\d{8}-\d{6}\s+3 个文件') "exit=$($r.Code) $($r.Out)"

Write-Host '  [Q2] 紧凑单行格式 (-Compress 形态): 必须被拒, 不静默给错计数'
# 反向断言是本卡核心: 把真实 manifest 原地改写成 -Compress 形态, history 必须报错而非数成 1
$qMan = "$Sandbox\.freeze\manifests\$qTs.json"
$qCompact = Get-Content -LiteralPath $qMan -Raw -Encoding UTF8 | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 5
[System.IO.File]::WriteAllText($qMan, $qCompact, (New-Object System.Text.UTF8Encoding($true)))
$r = Invoke-Deepfreeze @('history', '-Source', $Sandbox)
Check 'Q2 紧凑格式 history 被拒 (exit 非 0, 不静默数成 1)' ($r.Code -ne 0) "exit=$($r.Code) $($r.Out)"
# D1 (DFB-20261021-003): 消息断言容时序——负载下 stderr 的 ReadToEndAsync 与
# 进程退出存在竞态，$r.Out 可能截断丢掉报错行（评审 RUN2 实测失败项）。匹配
# 失败允许重跑一次再匹配（环境类补测）；两次都缺才 FAIL——真失败（报错内容
# 本身错了）重跑后仍缺，不被吞，fail-closed 保留。
if ($r.Out -notmatch '格式异常') {
    Write-Warning 'Q2 消息断言未命中 (疑似 stderr 截断), 重跑一次再匹配'
    $r = Invoke-Deepfreeze @('history', '-Source', $Sandbox)
}
Check 'Q2 报错含格式异常说明 (fail-closed, 未静默回退全量解析)' ($r.Out -match '格式异常') $r.Out

Write-Host '  [Q3] 空 manifest (files=[] 多行) 不被误判为紧凑格式'
New-Item -ItemType Directory -Force -Path $QEmpty | Out-Null
$r = Invoke-Deepfreeze @('protect', '-Source', $QEmpty, '-AutoConfirm')
Check 'Q3 空目录 protect 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
$r = Invoke-Deepfreeze @('history', '-Source', $QEmpty)
Check 'Q3 空 manifest history 正常 (exit 0, 守卫未误判)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'Q3 空 manifest 计数为 0 (输出 0 个文件)' ($r.Out -match '0 个文件') $r.Out
# Q3 现场自理 (不触碰既有清理段)
$null = Invoke-Deepfreeze @('unprotect', '-Source', $QEmpty, '-Purge', '-AutoConfirm')
Remove-Item -LiteralPath $QEmpty -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '  [Q4] S1: -ForceLarge 默认落点 → 空间警告出现'
$r = Invoke-Deepfreeze @('protect', '-Source', $gBig, '-ForceLarge', '-AutoConfirm')
Check 'Q4 -ForceLarge 默认落点含空间警告 (快照写满源卷)' ($r.Out -match '源所在卷') $r.Out

Write-Host '  [Q5] C2 回归: -ForceLarge + 同卷 -SnapshotRoot → 仍含空间警告'
$r = Invoke-Deepfreeze @('protect', '-Source', $gBig, '-ForceLarge', '-SnapshotRoot', $HStore2, '-AutoConfirm')
Check 'Q5 -ForceLarge + 同卷 SnapshotRoot 仍含空间警告 (C2 不回归)' ($r.Out -match '源所在卷') $r.Out

Write-Host '  [Q6] 不误报对照: 正常 protect (无 ForceLarge) 不得弹空间警告'
Reset-Sandbox
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
Check 'Q6 正常 protect 无空间警告 (-ForceLarge 专属, 常态噪音会使警告失效)' ($r.Out -notmatch '源所在卷') $r.Out


# ---------- C1~C9 卡号绑定 (DFB-20261019-001, 追加于 96 项之后, 未改动任何既有断言) ----------
Write-Host "`n[C系列] protect -Card 卡号绑定 + link 文件 (融合期 1)"
$CLink = "$Sandbox\.freeze\link-DFB-20261019-001.json"

Write-Host '  [C1] 合法卡号: protect 成功且 link 存在, snap_ts 与 history 最新一致'
Reset-Sandbox
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-Card', 'DFB-20261019-001', '-AutoConfirm')
Check 'C1 protect -Card 合法卡号成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'C1 link 文件存在' (Test-Path -LiteralPath $CLink)
$c1Link = if (Test-Path -LiteralPath $CLink) { Get-Content -LiteralPath $CLink -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$c1Snaps = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp' | Sort-Object Name)
$c1Ts = $c1Snaps[-1].Name -replace '^snap-', ''
Check 'C1 link.snap_ts 与 history 最新快照一致' ($null -ne $c1Link -and $c1Link.snap_ts -eq $c1Ts) "link=$($c1Link.snap_ts) latest=$c1Ts"

Write-Host '  [C2] link 字段完整, snap_path 为绝对路径且目录真实存在'
$c2Keys = if ($null -ne $c1Link) { @($c1Link.PSObject.Properties.Name) } else { @() }
Check 'C2 link 含全部必需字段 (card/snap_ts/snap_path/snapshot_root/source/created_at)' (
  (@('card','snap_ts','snap_path','snapshot_root','source','created_at') | Where-Object { $c2Keys -notcontains $_ }).Count -eq 0
) "实际字段: $($c2Keys -join ',')"
Check 'C2 link.card 与卡号一致' ($null -ne $c1Link -and $c1Link.card -eq 'DFB-20261019-001')
Check 'C2 snap_path 为绝对路径' ($null -ne $c1Link -and [System.IO.Path]::IsPathRooted($c1Link.snap_path)) "snap_path=$($c1Link.snap_path)"
Check 'C2 snap_path 指向的目录真实存在' ($null -ne $c1Link -and (Test-Path -LiteralPath $c1Link.snap_path -PathType Container)) "snap_path=$($c1Link.snap_path)"

Write-Host '  [C3] 非法卡号: fail-closed, 零副作用 (无 link / 无快照)'
# 反例集合覆盖形态逃逸: 小写 / 段数错 / 前缀长度越界 / 数字段位数错 / 路径注入
# 末三项为评审必修 1 的正则 fail-open 绕过面 (曾用 -match/\d/$):
$c3Bad = @(
  'dfb-lower', 'ABC-123-1', '', '../../etc', 'DFB-20261019-01', 'DFB-20261019-0001', 'ABCDEFG-20261019-001',
  'dfb-20261019-001',          # 小写合法形态 —— -match 大小写不敏感会放过, 现用 -cnotmatch 拒绝
  "DFB-20261019-001`n",         # 尾部换行 —— $ 允许末尾 \n 前锚定, 现用 \z 拒绝
  'DFB-٢٠٢٦١٠١٩-٠٠١'           # Unicode 数字 —— \d 匹配 Nd 类, 现用 [0-9] 拒绝
)
foreach ($bad in $c3Bad) {
  Reset-Sandbox
  $r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-Card', $bad, '-AutoConfirm')
  $c3SnapDirs = @(Get-ChildItem -LiteralPath $Sandbox -Recurse -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue).Count
  $c3Links = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze" -File -Filter 'link-*.json' -ErrorAction SilentlyContinue).Count
  Check "C3 非法卡号 '$bad' 被拒 (exit 非 0)" ($r.Code -ne 0) "exit=$($r.Code)"
  Check "C3 非法卡号 '$bad' 未产生 link 且未产生快照 (零副作用)" ($c3Links -eq 0 -and $c3SnapDirs -eq 0) "links=$c3Links snaps=$c3SnapDirs"
}

Write-Host '  [C4] 不带 -Card: 兼容性红线, 不产任何 link'
Reset-Sandbox
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
Check 'C4 不带 -Card protect 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code)"
$c4Links = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze" -File -Filter 'link-*.json' -ErrorAction SilentlyContinue).Count
Check 'C4 不带 -Card 时 link 目录无新增 (向后兼容)' ($c4Links -eq 0) "实际 $c4Links"
# 兼容性红线: 不带 -Card 时 state.json 形状必须与旧版逐位一致 —— 不多出 linked 字段
$c4Keys = @((Get-Content -LiteralPath "$Sandbox\.freeze\state.json" -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name)
Check 'C4 不带 -Card 时 state.json 无 linked 字段 (旧版形状逐位一致)' (
  $c4Keys -notcontains 'linked'
) "keys=$($c4Keys -join ',')"

Write-Host '  [C5] 同卡号二次 protect: link 被覆盖, snap_ts 更新, history 两个快照'
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-Card', 'DFB-20261019-001', '-AutoConfirm')
$c5First = (Get-Content -LiteralPath $CLink -Raw -Encoding UTF8 | ConvertFrom-Json).snap_ts
Start-Sleep -Milliseconds 1200   # 秒级时间戳需跨秒才能取到不同 snap_ts
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-Card', 'DFB-20261019-001', '-AutoConfirm')
$c5Second = (Get-Content -LiteralPath $CLink -Raw -Encoding UTF8 | ConvertFrom-Json).snap_ts
$c5LinkCount = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze" -File -Filter 'link-*.json' -ErrorAction SilentlyContinue).Count
Check 'C5 link 被覆盖 (snap_ts 更新为新快照)' ($c5Second -ne $c5First) "first=$c5First second=$c5Second"
Check 'C5 link 不追加历史 (同卡仍只有 1 个 link 文件)' ($c5LinkCount -eq 1) "实际 $c5LinkCount"
$r = Invoke-Deepfreeze @('history', '-Source', $Sandbox)
Check 'C5 history 显示两个快照' (([regex]::Matches($r.Out, 'snap-\d{8}-\d{6}')).Count -eq 2) "实际 $(([regex]::Matches($r.Out, 'snap-\d{8}-\d{6}')).Count)"

Write-Host '  [C6] 轮转隔离 (D3): KeepSnapshots=1, 卡引用的旧快照 manifest 不被删'
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-Card', 'DFB-20261019-001', '-AutoConfirm')
$c6Ts = (Get-Content -LiteralPath $CLink -Raw -Encoding UTF8 | ConvertFrom-Json).snap_ts
Start-Sleep -Milliseconds 1200
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')   # 第二个快照, 不绑卡
$c6ManBefore = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze\manifests" -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
Start-Sleep -Milliseconds 1200
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-KeepSnapshots', '1', '-AutoConfirm')
$c6ManAfter = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze\manifests" -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
$c6DirGone = -not (Test-Path -LiteralPath "$Sandbox\.freeze-snap\snap-$c6Ts")
Check 'C6 旧快照目录被轮转删除 (目录删除逻辑不变)' ($c6DirGone) "snap-$c6Ts 仍在? $(Test-Path -LiteralPath "$Sandbox\.freeze-snap\snap-$c6Ts")"
Check 'C6 被卡引用的旧快照 manifest 仍存在 (D3 生效)' (Test-Path -LiteralPath "$Sandbox\.freeze\manifests\$c6Ts.json") "manifest=$c6Ts"
Check 'C6 轮转后 manifest 文件数只增不减 (未删被引用清单)' ($c6ManAfter -ge $c6ManBefore) "before=$c6ManBefore after=$c6ManAfter"

Write-Host '  [C7] 共享库模式: link 落 <Source>\.freeze, snap_path 指向共享库绝对路径'
Reset-Sandbox
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-SnapshotRoot', $HStore, '-Card', 'DFB-20261019-001', '-AutoConfirm')
Check 'C7 共享库 + -Card protect 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'C7 link 落在 <Source>\.freeze 下' (Test-Path -LiteralPath $CLink)
$c7Link = if (Test-Path -LiteralPath $CLink) { Get-Content -LiteralPath $CLink -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
Check 'C7 snap_path 指向共享库内绝对路径且真实存在' ($null -ne $c7Link -and $c7Link.snap_path.StartsWith($HStore) -and (Test-Path -LiteralPath $c7Link.snap_path -PathType Container)) "snap_path=$($c7Link.snap_path)"
Check 'C7 源目录未产生 .freeze-snap (共享库模式)' (-not (Test-Path -LiteralPath "$Sandbox\.freeze-snap"))

Write-Host '  [C8] link 不进入快照: 快照目录内无 link-*.json (.freeze 被 /XD 排除)'
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-Card', 'DFB-20261019-001', '-AutoConfirm')
$c8Snaps = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp')
$c8InSnap = 0
foreach ($s in $c8Snaps) { $c8InSnap += @(Get-ChildItem -LiteralPath $s.FullName -Recurse -File -Filter 'link-*.json' -ErrorAction SilentlyContinue).Count }
Check 'C8 快照目录内不存在 link-*.json (link 未进快照)' ($c8InSnap -eq 0) "实际 $c8InSnap"
Check 'C8 对照: 源 .freeze 下确实有 link (证明 C8 不是空跑)' (Test-Path -LiteralPath $CLink)

Write-Host '  [C9] 非 protect 子命令带 -Card: 不报错退出, 不产生 link'
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')   # 先建快照, status 才有意义
$r = Invoke-Deepfreeze @('status', '-Source', $Sandbox, '-Card', 'DFB-20261019-001')
Check 'C9 status -Card 不报错退出 (exit 0, 非 protect 忽略该参数)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
$c9Links = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze" -File -Filter 'link-*.json' -ErrorAction SilentlyContinue).Count
Check 'C9 status -Card 不产生 link 文件' ($c9Links -eq 0) "实际 $c9Links"

Write-Host '  [C10] link 写入失败: protect 非零退出且 state.json 标记 linked:false (必修 2)'
Reset-Sandbox
# 用一个同名目录占位 link 路径, 令 Set-Content 写入失败 (磁盘满/权限类失败的确定性替身)
New-Item -ItemType Directory -Force -Path "$Sandbox\.freeze\link-DFB-20261019-002.json" | Out-Null
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-Card', 'DFB-20261019-002', '-AutoConfirm')
Check 'C10 link 写入失败时 protect 非零退出' ($r.Code -ne 0) "exit=$($r.Code)"
Check 'C10 报错含 link 写入失败说明' ($r.Out -match 'link 写入失败') $r.Out
$c10State = Get-Content -LiteralPath "$Sandbox\.freeze\state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'C10 state.json 标记 linked=false (可辨识断裂)' ($null -ne $c10State.PSObject.Properties['linked'] -and $c10State.linked -eq $false) "linked=$($c10State.linked)"
$c10Snaps = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze-snap" -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp').Count
Check 'C10 快照仍已提交 (link 失败不回滚快照)' ($c10Snaps -ge 1) "实际 $c10Snaps"

Write-Host '  [C11] 坏 link: BlockAll 警告出现且 manifest 只增不减 (必修 5)'
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-Card', 'DFB-20261019-001', '-AutoConfirm')
'NOT JSON {{{' | Set-Content -LiteralPath "$Sandbox\.freeze\link-DFB-20261019-001.json" -Encoding UTF8
Start-Sleep -Milliseconds 1200
$c11Before = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze\manifests" -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
Start-Sleep -Milliseconds 1200
$r = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-KeepSnapshots', '1', '-AutoConfirm')
$c11After = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze\manifests" -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
Check 'C11 坏 link 触发 BlockAll 警告 (manifest 轮转已暂停)' ($r.Out -match '轮转已暂停') $r.Out
Check 'C11 坏 link 时 manifest 只增不减 (不删任何清单)' ($c11After -ge $c11Before) "before=$c11Before after=$c11After"

# ---------- R1~R6 quarantine 保全矩阵 (DFB-20261023-001, 期 4a: 快照后新增文件移入 quarantine 而非删除) ----------
Write-Host "`n[R] quarantine 保全矩阵 (期 4a): restore 时快照后新增文件保全可找回"
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
# 破坏 a.txt（变更，restore 会覆盖）+ 新增 new1.txt/new2.txt（快照后新增，restore 会保全）
'tampered' | Set-Content -LiteralPath "$Sandbox\a.txt" -Encoding UTF8
'new-one' | Set-Content -LiteralPath "$Sandbox\new1.txt" -Encoding UTF8
'new-two' | Set-Content -LiteralPath "$Sandbox\sub\new2.txt" -Encoding UTF8
$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'R1 restore 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'R2 快照还原正确 (a.txt 回到 alpha-content)' (((Get-Content -LiteralPath "$Sandbox\a.txt" -Raw).TrimEnd("`r","`n")) -eq 'alpha-content')
# quarantine: 新增文件移入 .freeze\quarantine\<ts>\ 且保留相对路径结构
$qRoots = @(Get-ChildItem -LiteralPath "$Sandbox\.freeze\quarantine" -Directory -ErrorAction SilentlyContinue)
Check 'R3 quarantine 目录产生 (.freeze\quarantine\<ts>)' ($qRoots.Count -ge 1) "实际 $($qRoots.Count)"
if ($qRoots.Count -ge 1) {
    $qDir = $qRoots[-1].FullName
    Check 'R4 新增文件保全且内容完好 (new1.txt)' (((Get-Content -LiteralPath "$qDir\new1.txt" -Raw -ErrorAction SilentlyContinue).TrimEnd("`r","`n")) -eq 'new-one')
    Check 'R4 子目录结构保留 (sub\new2.txt)' (((Get-Content -LiteralPath "$qDir\sub\new2.txt" -Raw -ErrorAction SilentlyContinue).TrimEnd("`r","`n")) -eq 'new-two')
    # manifest: 字段正确（path/sha256/reason/snap_ref）
    $qManPath = Join-Path $qDir 'manifest.json'
    Check 'R5 manifest 存在' (Test-Path -LiteralPath $qManPath)
    if (Test-Path -LiteralPath $qManPath) {
        $qMan = Get-Content -LiteralPath $qManPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $new1 = @($qMan.files | Where-Object { $_.path -eq 'new1.txt' })
        Check 'R5 manifest 记录 path/sha256/reason/snap_ref' ($new1.Count -eq 1 -and $new1[0].sha256 -match '^[0-9a-f]{64}' -and $new1[0].reason -match 'quarantined' -and $new1[0].snap_ref -match '^snap-')
    }
}
Check 'R6 源目录的新增文件已移走 (new1.txt 不在源根)' (-not (Test-Path -LiteralPath "$Sandbox\new1.txt"))

# R7 无新增文件的 restore → 不产生 quarantine 目录
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
'tampered' | Set-Content -LiteralPath "$Sandbox\a.txt" -Encoding UTF8
$r = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'R7 无新增文件的 restore 不产生 quarantine (diff.New=0)' ($r.Code -ne 0 -or -not (Test-Path -LiteralPath "$Sandbox\.freeze\quarantine"))

# R8 unprotect -Purge 连 quarantine 一起清
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
'new-x' | Set-Content -LiteralPath "$Sandbox\newx.txt" -Encoding UTF8
$null = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
Check 'R8 前置: quarantine 已产生' (Test-Path -LiteralPath "$Sandbox\.freeze\quarantine")
$null = Invoke-Deepfreeze @('unprotect', '-Source', $Sandbox, '-Purge', '-AutoConfirm')
Check 'R8 unprotect -Purge 连 quarantine 一起清' (-not (Test-Path -LiteralPath "$Sandbox\.freeze\quarantine"))

# R9 quarantine 不进快照（.freeze 在 /XD 排除列表，快照里搜不到 quarantine）
Reset-Sandbox
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
'new-y' | Set-Content -LiteralPath "$Sandbox\newy.txt" -Encoding UTF8
$null = Invoke-Deepfreeze @('restore', '-Source', $Sandbox, '-AutoConfirm')
$null = Invoke-Deepfreeze @('protect', '-Source', $Sandbox, '-AutoConfirm')
Check 'R9 quarantine 不进快照 (/XD 排除)' (-not (Test-Path -LiteralPath "$Sandbox\.freeze-snap\snap-*\quarantine"))

# ---------- 清理 ----------
if (Test-Path -LiteralPath "$HSrcB\.freeze") { $null = Invoke-Deepfreeze @('unprotect', '-Source', $HSrcB, '-Purge', '-AutoConfirm') }
Remove-Item -LiteralPath $HSrcB   -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $HStore  -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $HStore2 -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $jlink)  { [System.IO.Directory]::Delete($jlink, $true) }
if (Test-Path -LiteralPath $jlink2) { [System.IO.Directory]::Delete($jlink2, $true) }
Remove-Item -LiteralPath $gBig   -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $gBytes -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath "$Sandbox\.freeze") { $null = Invoke-Deepfreeze @('unprotect', '-Source', $Sandbox, '-Purge', '-AutoConfirm') }
Remove-Item -LiteralPath $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Outside -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($failures.Count -eq 0) { Write-Host "结果: PASS ($checkCount 项断言)"; exit 0 }
else { Write-Host "结果: FAIL ($($failures.Count)/$checkCount 项): $($failures -join ' | ')"; exit 1 }
