# deepfreeze — 目录级「重启还原」试点

PowerShell 5.1 实现，零依赖（仅用系统自带 robocopy / Get-FileHash）。

## 用法

```powershell
# 保护（快照当前状态）
.\deepfreeze.ps1 protect -Source "D:\15812\mo brain\ximo"

# 查看状态
.\deepfreeze.ps1 status -Source "D:\15812\mo brain\ximo"

# 还原（快照后新增的文件会被删除 —— 冰点语义；确认前输出 diff 预览）
.\deepfreeze.ps1 restore -Source "D:\15812\mo brain\ximo" -KeepBackups 5

# 解除保护（快照保留；-Purge 连快照一起删）
.\deepfreeze.ps1 unprotect -Source "D:\15812\mo brain\ximo"
```

## 目录布局（保护目标内）

```
<Source>\
├─ .freeze\            # state.json + actions.log + prerestore-*\ 自动备份
└─ .freeze-snap\current\   # 快照镜像 + manifest.json（SHA256 清单）
```

## 安全设计

| 机制 | 说明 |
|---|---|
| 路径边界 | 默认仅允许 `D:\15812\` 下目标；**链接（junction/symlink）按真实目标判定**，指向界外一律拒绝 |
| 越界双确认 | 越界路径除 `-Force` 外还需 ShouldContinue 二次确认 |
| 还原前备份 | restore 前自动打 `prerestore-<时间戳>`，默认保留最近 3 份（`-KeepBackups` 可调） |
| 哈希校验 | restore 后按 manifest 校验全部文件；**文件被锁计入漂移并明确报出**，不会半路崩溃（throw 终止，不用 exit N，不杀调用方 shell） |
| 拒绝裸奔 | 未 protect 时 restore 直接抛错拒绝；快照目录被删同样拒绝 |
| 确认门槛 | protect/restore/unprotect 走 Test-Gate（ShouldProcess 支持 -WhatIf + ShouldContinue 必弹确认）；`-AutoConfirm` 供脚本跳过 |

## 自检

```powershell
.\verify.ps1   # 核心正/负路径 + T1锁文件/T2快照缺失/T3备份轮转/T4 Unicode名/T5 junction穿透/T6 purge重保护; PASS=exit 0
```

## 已知边界

- 保护对象是**普通数据目录**；系统目录、注册表、驱动不在范围内（那是真 DeepFreeze 的活）
- `/MIR` 会删目标里快照后新增的文件——这是特性不是 bug，但被保护目录别当垃圾场
- 本工具不驻留内存、不加驱动，还原发生在你**主动调用** restore 时（语义是「可回滚」而非「强制冰封」）；要真·开机自动还原，再挂计划任务（未实现，等试点验证后加）

## 文件

| 文件 | 角色 |
|---|---|
| `deepfreeze.ps1` | 主脚本 |
| `verify.ps1` | 自检 |
| `PROBE-README.md` | Ximo 沙箱读权限探针 |
| `_selftest\` | 自检夹具（自动重建） |
