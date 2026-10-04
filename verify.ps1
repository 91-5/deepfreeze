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

function Invoke-Deepfreeze {
  param([string[]]$DfArgs)
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'   # 子进程 stderr 是预期内输出, 不许终止本脚本
  try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @DfArgs 2>&1
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prevEap }
  $text = ($out | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ } }) -join "`n"
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
$gBytes = Join-Path $Root '_selftest\guard-bytes'
if (Test-Path -LiteralPath $gBytes) { Remove-Item -LiteralPath $gBytes -Recurse -Force }
New-Item -ItemType Directory -Force -Path $gBytes | Out-Null
$mbBuf = New-Object byte[] (1MB)
1..501 | ForEach-Object { [System.IO.File]::WriteAllBytes((Join-Path $gBytes "b$_.bin"), $mbBuf) }
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

# ---------- 清理 ----------
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
