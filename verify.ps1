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
Check 'H4 共享库快照总数=3 (A:2 + B:1, 各源隔离无混写)' ($hSnaps.Count -eq 3) "实际 $($hSnaps.Count)"

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
# 现场复用: H4 起 $HSrcB 即共享库模式 ($HStore\<keyB>), $HStore 同时含 Sandbox 早期写入的
# keyA (2 快照) —— 天然的「两源一库」现场, purge $HSrcB 后 keyA 必须原样存活。
New-Item -ItemType Directory -Force -Path "$HSrcB\.freeze-snap\snap-20260101-000000" | Out-Null
'legacy-orphan' | Set-Content -LiteralPath "$HSrcB\.freeze-snap\snap-20260101-000000\legacy.txt" -Encoding UTF8
$h8KeysBefore = @(Get-ChildItem -LiteralPath $HStore -Directory -ErrorAction SilentlyContinue)
Check 'H8 前置: purge 前 store 含 2 个 srcKey' ($h8KeysBefore.Count -eq 2) "实际 $($h8KeysBefore.Count)"
$r = Invoke-Deepfreeze @('unprotect', '-Source', $HSrcB, '-Purge', '-AutoConfirm')
Check 'H8 共享库模式 unprotect -Purge 成功 (exit 0)' ($r.Code -eq 0) "exit=$($r.Code) $($r.Out)"
Check 'H8 ①默认位置遗留快照被清 (.freeze-snap 不复存在)' (-not (Test-Path -LiteralPath "$HSrcB\.freeze-snap"))
$h8KeysAfter = @(Get-ChildItem -LiteralPath $HStore -Directory -ErrorAction SilentlyContinue)
Check 'H8 ②他源 srcKey 存活 (store 剩 1 个 key, 未越界清库)' ($h8KeysAfter.Count -eq 1) "实际 $($h8KeysAfter.Count)"
Check 'H8 ②他源快照数据完好 (keyA 的 2 个 snap 原样)' ((@(Get-ChildItem -LiteralPath $HStore -Recurse -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue | Where-Object Name -notlike '*.tmp')).Count -eq 2)
Check 'H8 ③actions.log 审计日志保留 (C3 裁定)' (Test-Path -LiteralPath "$HSrcB\.freeze\actions.log")
Check 'H8 ③日志含孤儿清理记录 (分支执行可追溯)' ((Get-Content -LiteralPath "$HSrcB\.freeze\actions.log" -Raw -ErrorAction SilentlyContinue) -match '同时清理默认位置的遗留快照')

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
