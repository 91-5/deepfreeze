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
  退出码: 0 = PASS, 1 = FAIL
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script = Join-Path $Root 'deepfreeze.ps1'
$Sandbox = Join-Path $Root '_selftest\data'
$Outside = Join-Path ([System.IO.Path]::GetTempPath()) 'deepfreeze-t5-outside'  # 必须在 D:\15812\ 之外(系统 TEMP 在 C 盘)

$failures = @()
function Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
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
Remove-Item -LiteralPath "$Sandbox\.freeze-snap\current" -Recurse -Force
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

# ---------- 清理 ----------
if (Test-Path -LiteralPath $jlink)  { [System.IO.Directory]::Delete($jlink, $true) }
if (Test-Path -LiteralPath $jlink2) { [System.IO.Directory]::Delete($jlink2, $true) }
if (Test-Path -LiteralPath "$Sandbox\.freeze") { $null = Invoke-Deepfreeze @('unprotect', '-Source', $Sandbox, '-Purge', '-AutoConfirm') }
Remove-Item -LiteralPath $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Outside -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($failures.Count -eq 0) { Write-Host '结果: PASS'; exit 0 }
else { Write-Host "结果: FAIL ($($failures.Count) 项): $($failures -join ' | ')"; exit 1 }
