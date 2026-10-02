#requires -Version 5.1
<#
.SYNOPSIS
  deepfreeze.ps1 — 目录级「重启还原」(DeepFreeze 式) 试点实现
.DESCRIPTION
  四个子命令: protect / restore / status / unprotect
  安全边界: 默认只允许 D:\15812\ 下的目标目录; 链接(junction/symlink)按真实目标判定, 其他路径需显式 -Force
  快照布局: <Source>\.freeze-snap\current  (robocopy 镜像, 内含 manifest.json)
  状态与日志: <Source>\.freeze\state.json, actions.log
  向导: restore 前自动打 pre-restore 备份(默认保留最近 3 份); restore 后按 manifest 校验哈希
  退出码: 0 = 成功; 非 0 = 失败(脚本内用 throw, 终止性错误; 不再用 exit N 以免杀死调用方 shell)
.EXAMPLE
  .\deepfreeze.ps1 protect -Source "D:\15812\mo brain\ximo"
  .\deepfreeze.ps1 status   -Source "D:\15812\mo brain\ximo"
  .\deepfreeze.ps1 restore -Source "D:\15812\mo brain\ximo" -KeepBackups 5
  .\deepfreeze.ps1 unprotect -Source "D:\15812\mo brain\ximo"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('protect', 'restore', 'status', 'unprotect')]
  [string]$Action,

  [Parameter(Mandatory = $true)]
  [string]$Source,

  [int]$KeepBackups = 3,

  [switch]$Purge,
  [switch]$Force,

  [switch]$AutoConfirm
)

$ErrorActionPreference = 'Stop'
$AllowedRoot = 'D:\15812'

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
$SnapRoot = Join-Path $Source '.freeze-snap'
$StateDir = Join-Path $Source '.freeze'
$StateFile = Join-Path $StateDir 'state.json'
$LogFile = Join-Path $StateDir 'actions.log'
$ManifestFile = Join-Path $SnapRoot 'current\manifest.json'

function Get-State {
  if (Test-Path -LiteralPath $StateFile) {
    return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
  }
  return $null
}

function Get-ProtectedFiles {
  param([string]$Root)
  return Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
    Where-Object { $_.FullName -notlike "$Root\.freeze\*" -and $_.FullName -notlike "$Root\.freeze-snap\*" }
}

function Get-Manifest {
  param([string]$Root)
  $items = Get-ProtectedFiles -Root $Root
  $manifest = [ordered]@{
    created = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    files   = @()
  }
  foreach ($f in $items) {
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
    $manifest.files += [ordered]@{ path = $rel; size = $f.Length; sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
  }
  return $manifest
}

function Get-Diff {
  # 快速差异: 基于文件清单+size (性能优先; 权威判定仍是 restore 后的哈希校验)
  param([string]$Root)
  $man = Get-Content -LiteralPath $ManifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
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

switch ($Action) {

  'protect' {
    $state = Get-State
    if ($state -and $state.protected) { throw "已处于保护状态。先 unprotect 或直接 restore。" }
    New-Item -ItemType Directory -Force -Path $SnapRoot, $StateDir | Out-Null
    if (-not (Test-Gate -Description "protect: 镜像当前状态到 $SnapRoot\current")) { Write-Host '已取消'; return }
    Write-Log "protect 开始: $Source"
    Invoke-RobocopyMirror -Src $Source -Dst (Join-Path $SnapRoot 'current') -Delete
    $manifest = Get-Manifest -Root $Source
    ($manifest | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $ManifestFile -Encoding UTF8
    $newState = [ordered]@{
      source = $Source; protected = $true
      snapshot_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
      file_count = $manifest.files.Count
    }
    ($newState | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8
    Write-Log "protect 完成: $($manifest.files.Count) 个文件入快照"
  }

  'restore' {
    $state = Get-State
    if (-not $state -or -not $state.protected) { throw "未处于保护状态, 拒绝 restore (无快照可还原)" }
    if (-not (Test-Path -LiteralPath (Join-Path $SnapRoot 'current'))) { throw "快照目录缺失: $SnapRoot\current" }

    # diff 预览: 让用户在确认前知情 (REVIEW-001 建议 #5)
    $diff = Get-Diff -Root $Source
    $desc = "restore (镜像快照覆盖目标; 将删除 $($diff.New.Count) 个快照后新增文件, 覆盖/恢复 $($diff.Changed.Count + $diff.Missing.Count) 个文件, 快照共 $($diff.Total) 个)"
    Write-Log "diff 预览: 新增 $($diff.New.Count) / 变更 $($diff.Changed.Count) / 缺失 $($diff.Missing.Count) (快照 $($diff.Total) 个)"
    if (-not (Test-Gate -Description "restore: $desc")) { Write-Host '已取消'; return }

    # 1) 还原前自保: 当前状态先备份
    $preDir = Join-Path $StateDir ("prerestore-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Invoke-RobocopyMirror -Src $Source -Dst $preDir
    Write-Log "pre-restore 备份完成: $preDir"

    # 2) 镜像快照回源 (/MIR: 快照后新增的文件会被删除 —— 冰点的语义)
    Invoke-RobocopyMirror -Src (Join-Path $SnapRoot 'current') -Dst $Source -Delete
    Write-Log "restore 镜像完成"

    # 3) 备份轮转 (REVIEW-001 建议 #4)
    Remove-OldBackups

    # 4) 哈希校验
    $manifest = Get-Content -LiteralPath $ManifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $drift = 0
    foreach ($m in $manifest.files) {
      $fp = Join-Path $Source $m.path
      if (-not (Test-Path -LiteralPath $fp)) { Write-Log "  [漂移-缺文件] $($m.path)"; $drift++; continue }
      try { $h = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash }
      catch { Write-Log "  [漂移-不可读] $($m.path) (文件被锁?)"; $drift++; continue }
      if ($h -ne $m.sha256) { Write-Log "  [漂移-内容不符] $($m.path)"; $drift++ }
    }
    if ($drift -eq 0) { Write-Log "校验通过: $($manifest.files.Count) 个文件与 manifest 完全一致" }
    else { throw "校验发现 $drift 处漂移, restore 未完全成功 (已保留 pre-restore 备份)。请检查文件占用/权限后重试" }
  }

  'status' {
    $state = Get-State
    if (-not $state) { Write-Host "未保护: $Source (无 .freeze\state.json)"; return }
    $snapOk = Test-Path -LiteralPath (Join-Path $SnapRoot 'current')
    Write-Host "目标:   $($state.source)"
    Write-Host "状态:   $(if ($state.protected) { '已保护 (PROTECTED)' } else { '未保护' })"
    Write-Host "快照于: $($state.snapshot_at) ($($state.file_count) 个文件)"
    Write-Host "快照目录: $(if ($snapOk) { '完好' } else { '缺失!' })"
    # REVIEW-001 建议 #6: restore 前让用户知情
    if ($state.protected -and $snapOk) {
      $diff = Get-Diff -Root $Source
      Write-Host "快照后变更: 新增 $($diff.New.Count) 个 / 内容变更 $($diff.Changed.Count) 个 / 被删 $($diff.Missing.Count) 个"
      if ($diff.New.Count -gt 0) { Write-Host "  (restore 将删除这些新增文件: $($diff.New.Count) 个 —— 操作前请确认无未保存内容)" }
    }
  }

  'unprotect' {
    $state = Get-State
    if (-not $state -or -not $state.protected) { Write-Host "当前未处于保护状态"; return }
    if (-not (Test-Gate -Description 'unprotect' -ActionText 'unprotect')) { Write-Host '已取消'; return }
    if ($Purge) {
      Remove-Item -LiteralPath $SnapRoot -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
      Write-Log "unprotect + Purge: 快照与状态已删除"
    }
    else {
      $state.protected = $false
      ($state | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8
      Write-Log "unprotect: 状态置为未保护, 快照保留 (如需删除快照加 -Purge)"
    }
  }
}
