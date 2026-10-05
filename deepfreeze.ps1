#requires -Version 5.1
<#
.SYNOPSIS
  deepfreeze.ps1 — 目录级「重启还原」(DeepFreeze 式) 试点实现
.DESCRIPTION
  五个子命令: protect / restore / status / history / unprotect
  安全边界: 只允许 $AllowedRoot 下的目标目录。边界解析顺序 = 显式 -AllowedRoot → 环境变量
             DEEPFREEZE_ALLOWED_ROOT → 默认 'D:\15812'（仅当该路径确实存在时）; 三者都拿不到
             则拒绝启动（fail-closed, 不猜宽边界兜底）。
             链接(junction/symlink)按真实目标判定, 其他路径需显式 -Force
             规模护栏: protect 前置检查, 源=安全边界根/盘根/文件数>5000/字节数>500MB 一律拒绝
             (fail-closed), -AutoConfirm 不能绕过; 唯一逃生通道 -ForceLarge, 硬闯记入 actions.log
  快照布局: <Source>\.freeze-snap\snap-<yyyyMMdd-HHmmss>\  (每次 protect 新增一个, 不覆盖)
             或 -SnapshotRoot 指定共享库: <SnapshotRoot>\<srcKey>\snap-<ts> (srcKey=源路径哈希前12位,
             多源隔离; 位置持久化在 state.json 的 snapshot_root 字段, 其余子命令凭它读回)
  清单存放: <Source>\.freeze\manifests\<ts>.json  (集中存放, 不进快照目录 —— 防止 restore 时被 /MIR 拷回源根造成自我污染)
  状态与日志: <Source>\.freeze\state.json, actions.log
  向导: restore 前自动打 pre-restore 备份(默认保留最近 3 份); restore 后按 manifest 逐文件校验哈希;
        protect 后快照按 -KeepSnapshots(默认 5) 轮转
  退出码: 0 = 成功; 非 0 = 失败(脚本内用 throw, 终止性错误; 不再用 exit N 以免杀死调用方 shell)
.EXAMPLE
  .\deepfreeze.ps1 protect -Source "D:\15812\mo brain\ximo"
  .\deepfreeze.ps1 status   -Source "D:\15812\mo brain\ximo"
  .\deepfreeze.ps1 history  -Source "D:\15812\mo brain\ximo"
  .\deepfreeze.ps1 restore -Source "D:\15812\mo brain\ximo" -KeepBackups 5
  .\deepfreeze.ps1 restore -Source "D:\15812\mo brain\ximo" -Snapshot 20261002-150301
  .\deepfreeze.ps1 unprotect -Source "D:\15812\mo brain\ximo"
.EXAMPLE
  换机器/换用户时显式指定安全边界（或预先设 $env:DEEPFREEZE_ALLOWED_ROOT）
  .\deepfreeze.ps1 protect -Source "E:\work\proj" -AllowedRoot "E:\work"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('protect', 'restore', 'status', 'history', 'unprotect')]
  [string]$Action,

  [Parameter(Mandatory = $true)]
  [string]$Source,

  [int]$KeepBackups = 3,
  [int]$KeepSnapshots = 5,

  # restore 到指定时间戳的快照(见 history 输出); 不带则还原到最近一个
  [string]$Snapshot,

  # 安全边界根目录; 不带则依次取环境变量 DEEPFREEZE_ALLOWED_ROOT、默认 'D:\15812'
  [string]$AllowedRoot,

  [switch]$Purge,
  [switch]$Force,

  # 规模护栏(DFB-20261004-001)的显式逃生通道: 对边界根/盘根/超大规模目录仍要 protect 时使用。
  # 与 -Force(越安全边界)语义不同、分开计, 硬闯会 Write-Warning 并记入 actions.log 可追溯
  [switch]$ForceLarge,

  # 快照存储位置(DFB-20261005-002): 快照库可放到源目录之外(例: 源在 C 盘项目、快照落 D 盘),
  # 替代已废弃的手工 junction 方案(边界外快照库会被 robocopy /XD 当普通目录拷进快照, 滚雪球)。
  # 仅 protect 接收; 共享库模式下快照落 <SnapshotRoot>\<srcKey>\snap-<ts>,
  # srcKey = 解析后源路径(小写、斜杠归一)SHA256 前 12 位 —— 多源共用一库时隔离, 防 snap-<ts> 撞名
  # 导致 Get-SnapshotManifestPath 取到别人清单的数据损坏。
  # 不传时行为不变: <Source>\.freeze-snap。restore/status/history/unprotect 不接收该参数,
  # 从 .freeze\state.json 的 snapshot_root 字段读回实际位置(旧 state.json 无该字段则回落默认)。
  [string]$SnapshotRoot,

  [switch]$AutoConfirm
)

$ErrorActionPreference = 'Stop'

# 安全边界解析。刻意 fail-closed: 拿不到边界就拒绝启动, 不猜一个宽边界兜底——
# 边界配置错了应该「拒绝服务」, 而不是「默默放开到整盘」。
if (-not $AllowedRoot) {
  if ($env:DEEPFREEZE_ALLOWED_ROOT) {
    $AllowedRoot = $env:DEEPFREEZE_ALLOWED_ROOT
  } elseif (Test-Path -LiteralPath 'D:\15812') {
    $AllowedRoot = 'D:\15812'
  } else {
    throw '未指定安全边界, 已拒绝启动。请显式传入 -AllowedRoot <根目录>, 或设置环境变量 DEEPFREEZE_ALLOWED_ROOT。（不提供默认宽边界是刻意的: 边界宁严勿宽）'
  }
}
if (-not (Test-Path -LiteralPath $AllowedRoot -PathType Container)) {
  throw "安全边界根目录不存在或不是目录: '$AllowedRoot'（请检查 -AllowedRoot / DEEPFREEZE_ALLOWED_ROOT）"
}
# 归一化尾部反斜杠: 环境变量很容易写成 'D:\15812\', 而 Test-WithinAllowed
# 拼的是 "$AllowedRoot\", 双斜杠会让 StartsWith 永远失配
$AllowedRoot = $AllowedRoot.TrimEnd('\')

function Write-Log {
  param([string]$Message)
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$stamp] $Message"
  switch ($Action) {
    'status' { Write-Host $line }
    default  { Write-Host $line; Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
  }
}

function Test-WithinAllowed {
  param([string]$FullPath)
  return ($FullPath -eq $AllowedRoot -or $FullPath.StartsWith("$AllowedRoot\", [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-Gate {
  [CmdletBinding(SupportsShouldProcess = $true)]
  # 破坏性操作门禁: -AutoConfirm 跳过; 否则 ShouldProcess(-WhatIf 支持) + ShouldContinue(必弹确认)
  param([string]$Description, [string]$Target = $Source, [string]$ActionText = $Action)
  if ($script:AutoConfirm) { return $true }
  if (-not $PSCmdlet.ShouldProcess($Target, $ActionText)) { return $false }
  return $PSCmdlet.ShouldContinue("$Description`n`n确定继续?", "deepfreeze 破坏性操作确认")
}

function Resolve-SourcePath {  param([string]$PathArg)
  if (-not (Test-Path -LiteralPath $PathArg)) { throw "目标不存在: $PathArg" }
  $item = Get-Item -LiteralPath $PathArg -Force
  $full = $item.FullName
  $linkType = $null
  try { $linkType = $item.LinkType } catch { }
  if ($linkType) {
    # 链接按真实目标判定边界, 防 junction 穿透 (REVIEW-001 建议 #2)
    $realFull = $null
    try {
      $t = $item.Target[0]
      if ($t -is [System.IO.DirectoryInfo]) { $realFull = $t.FullName }
      elseif ($t -is [System.IO.FileInfo]) { $realFull = $t.FullName }
      else { $realFull = [string]$t }
    } catch { }
    if (-not $realFull) { throw "无法解析链接目标: $full ($linkType)" }
    if (-not (Test-WithinAllowed $realFull)) {
      throw "安全边界: '$full' 是指向 '$realFull' 的 $linkType, 真实目标在 $AllowedRoot\ 之外, 已拒绝 (T5 用例)"
    }
    $full = $realFull
  }
  if (Test-WithinAllowed $full) { return $full }
  if (-not $Force) {
    throw "安全边界: '$full' 不在 $AllowedRoot\ 之下。如确需保护该路径, 显式加 -Force (有数据风险, 请确认后使用)"
  }
  if (-not (Test-Gate -Description "跨越安全边界执行 $Action 于 $full")) { throw "用户取消 -Force 操作" }
  Write-Warning "已用 -Force 越过安全边界: $full"
  return $full
}

$Source = Resolve-SourcePath -PathArg $Source
$StateDir = Join-Path $Source '.freeze'
$ManifestsDir = Join-Path $StateDir 'manifests'
$StateFile = Join-Path $StateDir 'state.json'
$LogFile = Join-Path $StateDir 'actions.log'

function Get-State {
  if (Test-Path -LiteralPath $StateFile) {
    return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
  }
  return $null
}

function Get-SrcKey {
  # 源身份键 (DFB-20261005-002): 解析后源路径小写 + 斜杠归一后 SHA256 前 12 位 hex。
  # 多源共用一个 SnapshotRoot 时按 srcKey 分目录, snap-<ts> 不再跨源撞名;
  # 同一真实目录的别名路径(junction)解析后同源 → 同 key, 语义正确。
  # 12 hex = 48 bit: 两源撞 key 概率 ~2^-49 量级, 可读性换隔离性(卡内已确认取舍)。
  param([string]$Path)
  $norm = $Path.ToLowerInvariant().Replace('/', '\')
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($norm)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')).Substring(0, 12)
  } finally { $sha.Dispose() }
}

# ---- 快照根解析 (DFB-20261005-002) ----
# $SnapRoot 语义 = 本源专属快照目录: 默认模式 <Source>\.freeze-snap; 共享库模式 <SnapshotRoot>\<srcKey>。
# 优先级: protect 显式 -SnapshotRoot > state.json 记录(含共享库模式下的持续生效) > 默认位置(向后兼容)。
# 此处只做纯路径计算, 不创建任何目录 —— 落盘统一交给 protect 内的 New-Item,
# 保证规模护栏拒绝时零副作用(与 DFB-20261004-001 的零写入语义一致)。
$DefaultSnapRoot = Join-Path $Source '.freeze-snap'
$SnapRoot = $DefaultSnapRoot
if ($SnapshotRoot -and $Action -ne 'protect') {
  throw "-SnapshotRoot 仅对 protect 子命令生效; restore/status/history/unprotect 从 .freeze\state.json 的 snapshot_root 字段读取实际快照位置"
}
if ($Action -eq 'protect' -and $SnapshotRoot) {
  $store = $SnapshotRoot.TrimEnd('\')
  if (-not $store) { throw '-SnapshotRoot 不能是空路径' }
  $SnapRoot = Join-Path $store (Get-SrcKey -Path $Source)
}
else {
  $state0 = Get-State
  if ($state0 -and $state0.PSObject.Properties['snapshot_root'] -and $state0.snapshot_root) {
    $SnapRoot = [string]$state0.snapshot_root
  }
}

function Get-Snapshots {
  # 有效快照 = snap-<ts> 且不带 .tmp 后缀; .tmp 是 protect 中断的半成品, 任何统计都不得计入
  if (-not (Test-Path -LiteralPath $SnapRoot)) { return @() }
  return @(Get-ChildItem -LiteralPath $SnapRoot -Directory -Filter 'snap-*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '*.tmp' } | Sort-Object Name)
}

function Get-SnapshotManifestPath {
  # 清单集中存放在 .freeze\manifests\<ts>.json, 与快照目录按 ts 一一对应
  param([string]$Ts)
  return Join-Path $ManifestsDir "$Ts.json"
}

function Get-Sha256Hex {
  # .NET SHA256 实例复用: 354 文件量级下比逐次 Get-FileHash 快约 4 倍 (0.44s -> 0.10s, 实测)
  param([string]$Path, [System.Security.Cryptography.SHA256]$Sha)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return [System.BitConverter]::ToString($Sha.ComputeHash($bytes)).Replace('-', '')
}

function Get-ProtectedFiles {
  param([string]$Root)
  return Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
    Where-Object { $_.FullName -notlike "$Root\.freeze\*" -and $_.FullName -notlike "$Root\.freeze-snap\*" }
}

function Test-SourceScale {
  # 规模护栏 (DFB-20261004-001): 拦截整盘/边界级 protect。
  # 2026-10-03 两次事故 (C:\ 31.42GB/114,012 文件 与 D:\15812) 都是带 -AutoConfirm 的
  # 「合法调用」——Test-Gate 在 -AutoConfirm 下直接放行, 拦不住, 所以规模防线必须
  # 独立于确认门禁生效, 且对 -AutoConfirm 依然拒绝 (fail-closed)。
  # 排除语义直接复用 Get-ProtectedFiles (与 robocopy /XD 同一套), 不引入第三套排除规则。
  # 边界根/盘根是结构性拒绝, 不做枚举直接 fail-fast —— 对 C:\ 这类目标, 枚举本身
  # 就是事故的一部分。阈值调整只改本函数内两个常量。
  param([string]$Root)
  $FileCountLimit = 5000
  $ByteLimit = 500MB
  $reason = $null
  if ($Root -ieq $AllowedRoot) {
    $reason = "源目录就是安全边界本身 ($AllowedRoot)。边界内任何目录都可保护, 但边界根本身通常聚合了全部数据 (实测 D:\15812 = 33.9GB/33,777 文件)"
  }
  elseif ($Root -ieq [System.IO.Path]::GetPathRoot($Root)) {
    $reason = "源目录是盘根 ($Root)"
  }
  else {
    $files = @(Get-ProtectedFiles -Root $Root)
    $count = $files.Count
    $bytes = 0
    if ($count -gt 0) { $bytes = ($files | Measure-Object -Property Length -Sum).Sum }
    if ($count -gt $FileCountLimit) {
      $reason = "文件数 $count 超过阈值 $FileCountLimit"
    }
    elseif ($bytes -gt $ByteLimit) {
      # 措辞防歧义(返工单 C2): 原始字节与阈值不并排裸印, 阈值从常量换算, 改常量时消息自动一致
      $reason = '总字节数 {0}（约 {1:N1} MB）超过 {2:N0} MB 阈值' -f $bytes, ($bytes / 1MB), ($ByteLimit / 1MB)
    }
  }
  if (-not $reason) { return }
  if ($ForceLarge) {
    # 唯一逃生通道: 显式开关, 留痕到 actions.log, 让「当初是谁硬扛过去的」可追溯
    Write-Warning "规模护栏被 -ForceLarge 显式越过: $reason (源: $Root)"
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Write-Log "规模护栏被 -ForceLarge 越过: $reason (源: $Root)"
    return
  }
  throw @(
    "protect 已被规模护栏拒绝: $reason。",
    "阈值: 文件数 > $FileCountLimit 或总字节 > $ByteLimit (500 MB), 或源为边界根/盘根。",
    "请改用更具体的项目目录作 -Source (例: -Source `"D:\15812\projects\<项目名>`")。",
    "如确需保护大规模目录, 显式加 -ForceLarge (该操作会记入 actions.log)。"
  ) -join "`n"
}

function Get-Manifest {
  param([string]$Root)
  $items = Get-ProtectedFiles -Root $Root
  $manifest = [ordered]@{
    created = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    files   = @()
  }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    foreach ($f in $items) {
      $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
      $manifest.files += [ordered]@{ path = $rel; size = $f.Length; sha256 = (Get-Sha256Hex -Path $f.FullName -Sha $sha) }
    }
  } finally { $sha.Dispose() }
  return $manifest
}

function Get-Diff {
  # 快速差异: 基于文件清单+size (性能优先; 权威判定仍是 restore 后的哈希校验)
  param([string]$Root, [string]$ManifestPath)
  $man = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $manPaths = @{}
  foreach ($m in $man.files) { $manPaths[$m.path] = $m.size }
  $cur = @{}
  foreach ($f in (Get-ProtectedFiles -Root $Root)) {
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
    $cur[$rel] = $f.Length
  }
  $new = @(); $changed = @(); $missing = @()
  foreach ($p in $manPaths.Keys) {
    if (-not $cur.ContainsKey($p)) { $missing += $p }
    elseif ($cur[$p] -ne $manPaths[$p]) { $changed += $p }
  }
  foreach ($p in $cur.Keys) { if (-not $manPaths.ContainsKey($p)) { $new += $p } }
  return @{ New = $new; Changed = $changed; Missing = $missing; Total = $manPaths.Count }
}

function Invoke-RobocopyMirror {
  param([string]$Src, [string]$Dst, [switch]$Delete)
  $mirror = if ($Delete) { '/MIR' } else { '/E' }
  $args0 = @($Src, $Dst, $mirror, '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP',
    '/XD', (Join-Path $Source '.freeze'), (Join-Path $Source '.freeze-snap'))
  $null = & robocopy.exe @args0
  $code = $LASTEXITCODE
  # 0-7 成功(含复制); 8 部分失败(如目标文件被锁, T1 用例); >=16 致命
  if ($code -ge 16) { throw "robocopy 致命错误 (exit=$code): $Src -> $Dst" }
  if ($code -eq 8) { Write-Log "  robocopy 部分失败 (exit=8, 通常为文件被锁), 将继续由哈希校验判定" }
}

function Remove-OldBackups {
  $backups = Get-ChildItem -LiteralPath $StateDir -Directory -Filter 'prerestore-*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending
  if ($backups.Count -gt $KeepBackups) {
    $backups | Select-Object -Skip $KeepBackups | ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Recurse -Force
      Write-Log "  清理旧备份: $($_.Name)"
    }
  }
}

function Remove-OldSnapshots {
  # 快照按时间戳名升序, 最旧的排最前; 超出 $KeepSnapshots 的最旧快照连同其清单一起删
  $snaps = Get-Snapshots
  $excess = $snaps.Count - $KeepSnapshots
  if ($excess -gt 0) {
    $snaps | Select-Object -First $excess | ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Recurse -Force
      $ts = $_.Name -replace '^snap-', ''
      Remove-Item -LiteralPath (Get-SnapshotManifestPath -Ts $ts) -Force -ErrorAction SilentlyContinue
      Write-Log "  清理旧快照: $($_.Name)"
    }
  }
}

switch ($Action) {

  'protect' {
    # 规模护栏必须先于一切写操作(含下面 New-Item 建目录)执行, 拒绝时源目录零副作用
    Test-SourceScale -Root $Source
    # 共享库模式下在写之前明示实际落点 (卡 D2: 显式传参 + Write-Warning 记录, 不做路径边界校验)
    if ($SnapshotRoot) { Write-Warning "快照根: 本次快照写入指定存储 $SnapRoot (源: $Source; 快照不再落在源目录内)" }
    $state = Get-State
    $appendHint = if ($state -and $state.protected) { ' (已处于保护状态, 追加新快照)' } else { '' }
    New-Item -ItemType Directory -Force -Path $SnapRoot, $StateDir, $ManifestsDir | Out-Null
    # 同一秒内连打多个快照会同名冲突: 目标已存在时等时间戳走开
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $snapTarget = Join-Path $SnapRoot "snap-$ts"
    $tmpDir = "$snapTarget.tmp"
    while ((Test-Path -LiteralPath $snapTarget) -or (Test-Path -LiteralPath $tmpDir)) {
      Start-Sleep -Milliseconds 250
      $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
      $snapTarget = Join-Path $SnapRoot "snap-$ts"
      $tmpDir = "$snapTarget.tmp"
    }
    $manifestPath = Get-SnapshotManifestPath -Ts $ts
    if (-not (Test-Gate -Description "protect: 镜像当前状态到 $snapTarget$appendHint")) { Write-Host '已取消'; return }
    Write-Log "protect 开始: $Source (快照 snap-$ts)"
    # 原子提交: 先写 .tmp 临时目录, 全部成功后同卷 rename —— 快照要么完整存在, 要么不存在,
    # Ctrl+C/崩溃/磁盘满只会留下一个被各处统计忽略的 .tmp 残骸, 不会污染快照序列
    try {
      Invoke-RobocopyMirror -Src $Source -Dst $tmpDir -Delete
      $manifest = Get-Manifest -Root $Source
      ($manifest | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $manifestPath -Encoding UTF8
      Move-Item -LiteralPath $tmpDir -Destination $snapTarget
    }
    catch {
      Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
      throw
    }
    $newState = [ordered]@{
      source = $Source; protected = $true
      snapshot_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
      latest_snapshot = $ts
      file_count = $manifest.files.Count
      # 实际使用的快照目录绝对路径 (DFB-20261005-002): 共享库模式下 = <SnapshotRoot>\<srcKey>,
      # restore/status/history/unprotect 凭此字段找快照; 旧版 state.json 无此字段 → 回落默认位置
      snapshot_root = $SnapRoot
    }
    ($newState | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8
    Remove-OldSnapshots
    Write-Log "protect 完成: $($manifest.files.Count) 个文件入快照 snap-$ts"
  }

  'restore' {
    $state = Get-State
    if (-not $state -or -not $state.protected) { throw "未处于保护状态, 拒绝 restore (无快照可还原)" }
    # 解析目标快照: 带 -Snapshot 还原到指定时间点; 不带则还原到最近一个
    if ($Snapshot) {
      $snapDir = Join-Path $SnapRoot "snap-$Snapshot"
      if (-not (Test-Path -LiteralPath $snapDir)) { throw "快照不存在: snap-$Snapshot (用 history 查看可用快照)" }
      $ts = $Snapshot
    }
    else {
      $snaps = Get-Snapshots
      if ($snaps.Count -eq 0) { throw "快照目录缺失: $SnapRoot 下无任何 snap-* 快照" }
      $snapDir = $snaps[-1].FullName
      $ts = $snaps[-1].Name -replace '^snap-', ''
    }
    $manifestPath = Get-SnapshotManifestPath -Ts $ts
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "快照清单缺失: $manifestPath (快照 snap-$ts 不完整)" }

    # diff 预览: 让用户在确认前知情 (REVIEW-001 建议 #5)
    $diff = Get-Diff -Root $Source -ManifestPath $manifestPath
    $desc = "restore 到 snap-$ts (镜像快照覆盖目标; 将删除 $($diff.New.Count) 个快照后新增文件, 覆盖/恢复 $($diff.Changed.Count + $diff.Missing.Count) 个文件, 快照共 $($diff.Total) 个)"
    Write-Log "diff 预览: 新增 $($diff.New.Count) / 变更 $($diff.Changed.Count) / 缺失 $($diff.Missing.Count) (快照 $($diff.Total) 个)"
    if (-not (Test-Gate -Description "restore: $desc")) { Write-Host '已取消'; return }

    # 1) 还原前自保: 当前状态先备份
    $preDir = Join-Path $StateDir ("prerestore-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Invoke-RobocopyMirror -Src $Source -Dst $preDir
    Write-Log "pre-restore 备份完成: $preDir"

    # 2) 镜像快照回源 (/MIR: 快照后新增的文件会被删除 —— 冰点的语义)
    Invoke-RobocopyMirror -Src $snapDir -Dst $Source -Delete
    Write-Log "restore 镜像完成: snap-$ts -> $Source"

    # 3) 备份轮转 (REVIEW-001 建议 #4)
    Remove-OldBackups

    # 4) 哈希校验: 只遍历 manifest 列出的文件 (不重新枚举整个目录, 顺带绕开 Defender 冷启动)
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $drift = 0
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      foreach ($m in $manifest.files) {
        $fp = Join-Path $Source $m.path
        if (-not (Test-Path -LiteralPath $fp)) { Write-Log "  [漂移-缺文件] $($m.path)"; $drift++; continue }
        try { $h = Get-Sha256Hex -Path $fp -Sha $sha }
        catch { Write-Log "  [漂移-不可读] $($m.path) (文件被锁?)"; $drift++; continue }
        if ($h -ne $m.sha256) { Write-Log "  [漂移-内容不符] $($m.path)"; $drift++ }
      }
    }
    finally { $sha.Dispose() }
    if ($drift -eq 0) { Write-Log "校验通过: $($manifest.files.Count) 个文件与 manifest 完全一致" }
    else { throw "校验发现 $drift 处漂移, restore 未完全成功 (已保留 pre-restore 备份)。请检查文件占用/权限后重试" }
  }

  'status' {
    $state = Get-State
    if (-not $state) { Write-Host "未保护: $Source (无 .freeze\state.json)"; return }
    $snaps = Get-Snapshots
    $snapOk = ($snaps.Count -gt 0)
    Write-Host "目标:   $($state.source)"
    Write-Host "状态:   $(if ($state.protected) { '已保护 (PROTECTED)' } else { '未保护' })"
    Write-Host "快照于: $($state.snapshot_at) ($($state.file_count) 个文件)"
    Write-Host "快照:   $(if ($snapOk) { "$($snaps.Count) 个, 最近 $($snaps[-1].Name)" } else { '无 (缺失!)' })"
    # REVIEW-001 建议 #6: restore 前让用户知情
    if ($state.protected -and $snapOk) {
      $diff = Get-Diff -Root $Source -ManifestPath (Get-SnapshotManifestPath -Ts ($snaps[-1].Name -replace '^snap-', ''))
      Write-Host "快照后变更: 新增 $($diff.New.Count) 个 / 内容变更 $($diff.Changed.Count) 个 / 被删 $($diff.Missing.Count) 个"
      if ($diff.New.Count -gt 0) { Write-Host "  (restore 将删除这些新增文件: $($diff.New.Count) 个 —— 操作前请确认无未保存内容)" }
    }
  }

  'history' {
    $snaps = Get-Snapshots
    if ($snaps.Count -eq 0) { Write-Host "无快照: $SnapRoot"; return }
    Write-Host "快照历史 ($($snaps.Count) 个, 最新在后):"
    foreach ($s in $snaps) {
      $ts = $s.Name -replace '^snap-', ''
      $count = '?'
      $mp = Get-SnapshotManifestPath -Ts $ts
      if (Test-Path -LiteralPath $mp) {
        try { $m = Get-Content -LiteralPath $mp -Raw -Encoding UTF8 | ConvertFrom-Json; $count = @($m.files).Count } catch { }
      }
      $mark = if ($s -eq $snaps[-1]) { '  <- 最近' } else { '' }
      Write-Host "  $($s.Name)  $count 个文件$mark"
    }
  }

  'unprotect' {
    $state = Get-State
    if (-not $state -or -not $state.protected) { Write-Host "当前未处于保护状态"; return }
    if (-not (Test-Gate -Description 'unprotect' -ActionText 'unprotect')) { Write-Host '已取消'; return }
    if ($Purge) {
      Remove-Item -LiteralPath $SnapRoot -Recurse -Force -ErrorAction SilentlyContinue
      # 快照根迁到共享库后(DFB-20261005-002), 历史上落在默认位置的旧快照成为孤儿
      # (restore/history 已读不到)。-Purge 的语义是清空本源快照数据, 顺带清掉防残留;
      # 默认模式下两者同路径, 此分支不触发, 行为与迁移前完全一致
      if ($SnapRoot -ne $DefaultSnapRoot -and (Test-Path -LiteralPath $DefaultSnapRoot)) {
        Remove-Item -LiteralPath $DefaultSnapRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "  同时清理默认位置的遗留快照: $DefaultSnapRoot"
      }
      Remove-Item -LiteralPath $ManifestsDir -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
      # 措辞对齐实际行为(返工单 C3): -Purge 删快照/清单/状态, 但 actions.log 审计日志保留
      # (与本项目「事故可追溯」基调一致, 删审计日志比留它更糟), 故明说保留而非宣称全删
      Write-Log "unprotect + Purge: 快照与状态已删除 (actions.log 审计日志保留)"
    }
    else {
      $state.protected = $false
      ($state | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8
      Write-Log "unprotect: 状态置为未保护, 快照保留 (如需删除快照加 -Purge)"
    }
  }
}
