# deepfreeze — 目录级「重启还原」试点（项目级后悔药）

**Windows only**（依赖系统自带 `robocopy`，无跨平台计划），PowerShell 5.1，零第三方依赖
（仅用 robocopy / .NET SHA256）。

> **当前是手动工具，不是自动保护。** protect / restore 都由你**主动执行**；
> 没有计划任务常驻、没有文件监听、没有 hook 拦截。你**必须先 protect 打过快照**，
> 之后改崩了才能 restore。若期望「agent 一动文件就自动快照」，本项目**尚未实现**
> （见「已知边界」第 5 条）。

AI 在项目目录里把文件改坏、删掉、写坏了，能在秒级回到**任意一个你打过快照的时间点**，
并有 SHA256 逐文件校验确认还原正确。对本机实测规模（354 文件 / 6.4 MB），
完整还原（含哈希校验）约 0.7 秒。

## 用法

**第 0 步（换机器/换用户必做）——确认安全边界**。本工具只允许在被保护目录位于
**安全边界**（`AllowedRoot`）之下时才工作。解析顺序：

| 优先级 | 来源 | 说明 |
|---|---|---|
| 1 | `-AllowedRoot "D:\你的项目根"` | 命令行显式指定 |
| 2 | 环境变量 `DEEPFREEZE_ALLOWED_ROOT` | 临时/脚本内设置 |
| 3 | 默认 `D:\15812\` | **仅当该路径在本机存在时**才生效 |

三者都拿不到 → **脚本拒绝启动**（fail-closed，刻意不猜一个宽边界兜底）。
所以**在别人的机器上，第一步必须显式给边界**，否则会直接报错：

```powershell
# 换机器第一步：把边界指到你的实际根目录（下面所有命令都要能落在它之内）
.\deepfreeze.ps1 protect -Source "C:\你的项目" -AllowedRoot "C:\"
# 或改用环境变量（对本终端会话及子进程生效）
$env:DEEPFREEZE_ALLOWED_ROOT = "C:\你的项目根"
```

```powershell
# 保护（打一个新快照；已保护状态下再 protect 会追加快照，不覆盖）
.\deepfreeze.ps1 protect -Source "<你的目录>"

# 查看状态（含快照后变更 diff 预览）
.\deepfreeze.ps1 status -Source "<你的目录>"

# 查看快照历史（全部时间点与文件数）
.\deepfreeze.ps1 history -Source "<你的目录>"

# 还原到最近一个快照（快照后新增的文件会被删除 —— 冰点语义；确认前输出 diff 预览）
.\deepfreeze.ps1 restore -Source "<你的目录>" -KeepBackups 5

# 还原到指定历史时间点（时间戳见 history 输出）
.\deepfreeze.ps1 restore -Source "<你的目录>" -Snapshot 20261002-150301

# 解除保护（快照保留；-Purge 连快照、清单、状态一起删）
.\deepfreeze.ps1 unprotect -Source "<你的目录>"
```

> 上面示例用 `<你的目录>` 占位。边界默认值 `D:\15812\` 是**作者本机路径**，
> 在别的机器上通常不存在，此时必须按第 0 步显式配置。

快照轮转：每次 protect 后保留最近 N 个快照（默认 5，`-KeepSnapshots` 可调），超出删最旧。
protect 采用**先写临时目录、成功后原子 rename** 的提交方式——中断（Ctrl+C / 崩溃 / 磁盘满）
只会留下一个被 history 和轮转忽略的 `*.tmp` 残骸，不会污染快照序列。

## 目录布局（保护目标内）

```
<Source>\
├─ .freeze\                        # state.json + actions.log
│  ├─ manifests\<ts>.json          # 每个快照的 SHA256 清单（集中存放，按 ts 一一对应）
│  └─ prerestore-*\                # restore 前自动备份（默认保留最近 3 份，-KeepBackups 可调）
└─ .freeze-snap\
   ├─ snap-<yyyyMMdd-HHmmss>\      # 快照镜像（每次 protect 新增一个，不覆盖）
   └─ snap-<...>.tmp\              # protect 进行中的半成品（中断残留，不参与任何统计）
```

清单**刻意不放进快照目录**：restore 的 `robocopy /MIR` 源是快照目录，清单若在其中会被
原样拷回源根（自我污染，实测复现过的 bug），且快照越多泄漏越多。清单移到 `.freeze\manifests\`
后该目录已在 `/XD` 排除列表内，双向干净。

## 安全设计

| 机制 | 说明 |
|---|---|
| 路径边界 | 仅允许 `$AllowedRoot` 下目标；**链接（junction/symlink）按真实目标判定**，指向界外一律拒绝 |
| 边界配置 | 解析顺序：`-AllowedRoot` → 环境变量 `DEEPFREEZE_ALLOWED_ROOT` → 默认 `D:\15812\`（仅当该路径存在时）。三者都拿不到则**拒绝启动**——刻意 fail-closed，不猜一个宽边界兜底。换机器/换用户请显式配置 |
| 越界双确认 | 越界路径除 `-Force` 外还需 ShouldContinue 二次确认 |
| 还原前备份 | restore 前自动打 `prerestore-<时间戳>`，默认保留最近 3 份（`-KeepBackups` 可调） |
| 快照原子性 | protect 先写 `*.tmp` 临时目录，全部成功后同卷 rename 提交；半成品不进 history、不计轮转 |
| 哈希校验 | restore 后按 manifest 逐文件校验；**文件被锁计入漂移并明确报出**，不会半路崩溃（throw 终止，不用 exit N，不杀调用方 shell） |
| 拒绝裸奔 | 未 protect 时 restore 直接抛错拒绝；快照全部缺失同样拒绝 |
| 确认门槛 | protect/restore/unprotect 走 Test-Gate（ShouldProcess 支持 -WhatIf + ShouldContinue 必弹确认）；`-AutoConfirm` 供脚本跳过 |

## 自检

```powershell
.\verify.ps1
# 核心 正/负路径 + T1锁文件 / T2快照缺失 / T3备份轮转 / T4 Unicode名 / T5 junction穿透 / T6 purge重保护
# + N1清单不泄漏 / N2清单不自包含 / N3多快照 / N4 history / N5指定快照还原 / N6默认还原最近 / N7快照轮转 / N8 .tmp隔离
# PASS = exit 0（当前 39 项断言）
```

## 已知边界（这能做什么 / 不能做什么，请如实理解）

**✅ 能做**：项目目录内文件级的「回到任意快照时间点」——改坏、删错、写坏文件后的后悔药。

**❌ 不能做**（不在能力范围内，不是缺陷）：

1. **不覆盖「AI 动了系统文件」**——注册表、系统服务、环境变量、PATH、已安装软件，
   一律不管。那需要内核态过滤驱动（蓝屏风险、与 BitLocker 冲突、无独立安全审计），
   成本与本项目规模不成比例，已评估否决。
2. **不还原外部副作用**——已 push 的 git commit、已发出的 HTTP 请求、写入外部数据库、已发布的包。
3. **不还原外部依赖状态**——还原文件后，npm/pip 全局缓存与已装包仍是新版，下次运行行为可能与快照时刻不一致。
4. **挡不住 AI 主动解除保护**——快照目录就在被保护目录内，用户态无法防御。
5. **不是开机自动还原、也不是自动保护**——protect 与 restore 都由你**主动触发**；
   无计划任务常驻、无注册表自启、无文件监听、无 hook 拦截、无驱动级拦截。
   **「agent 一动手就自动打快照」这个形态目前不存在**，是被保护目录内手动管理快照的工具。
6. **不防多时间点之间的外部状态漂移**——只认文件内容，不认「世界」。

若将来确实需要「真·冰点」：唯一现实的下一阶段是 Hyper-V 差分磁盘 checkpoint
（整机进 VM，Windows 自带差分磁盘做整机快照，无需写驱动）。本工具不涉及此方向。

## 路线图（尚未实现，写在前面免得误解）

按价值排序，都**未实现**：

1. **接入 agent hook —— 危险操作前自动 protect**。这是把本项目从「手动工具」变成
   「agent 基础设施」的关键一步，也是与 `agent-undo` / `agent-rollback` 类工具的差异点。
   现状：**完全没有**，需要宿主（如 OpenCode）在写操作前暴露 hook 点。
2. **Linux/macOS 支持**——需重写文件操作层（去掉 `robocopy` 依赖），成本高，优先级低。
3. **条件触发快照**（如「目录变更超过 N 个文件时自动 protect」）——仍缺文件监听层。

其他边界：

- 保护对象是**普通数据目录**；`/MIR` 会删目标里快照后新增的文件——这是特性不是 bug，但被保护目录别当垃圾场
- `prerestore-*` 备份与快照是两套东西：快照是「回到某个时间点」，prerestore 是「还原出错时退回还原前」，语义不同，不合并

## 文件

| 文件 | 角色 |
|---|---|
| `deepfreeze.ps1` | 主脚本 |
| `verify.ps1` | 自检 |
| `PROBE-README.md` | Ximo 沙箱读权限探针 |
| `_selftest\` | 自检夹具（自动重建，已 gitignore） |
