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

# 保护 + 快照存到别处（-SnapshotRoot，DFB-20261005-002）
# 快照不再落在 <Source>\.freeze-snap，而是 <SnapshotRoot>\<srcKey>\snap-<ts>
# （srcKey = 源路径 SHA256 前 12 位，多源共用一库时互相隔离，snap-<ts> 不撞名）
.\deepfreeze.ps1 protect -Source "C:\某个项目" -AllowedRoot "C:\" -SnapshotRoot "D:\deepfreeze-store" -AutoConfirm
# 快照位置持久化在 <Source>\.freeze\state.json 的 snapshot_root 字段：
# restore / status / history / unprotect 不带任何位置参数，自动从该字段读回实际快照位置。
# 之后对该源的 protect 即使不带 -SnapshotRoot 也会继续落同一位置（显式传参可随时改）。
# 不传 -SnapshotRoot 时行为与旧版完全一致：<Source>\.freeze-snap。

# 保护 + 绑定任务卡号（-Card，融合期 1，DFB-20261019-001）
# 快照提交成功后写 <Source>\.freeze\link-<卡号>.json，供 agent-covenant 门禁（期 2）读取。
# 卡号须匹配 ^[A-Z]{2,6}-\d{8}-\d{3}$（如 DFB-20261019-001），否则 fail-closed 拒绝且零副作用。
# 不带 -Card 时行为与旧版逐位一致（完全不碰 link 目录）。
.\deepfreeze.ps1 protect -Source "C:\某个项目" -AllowedRoot "C:\" -Card "DFB-20261019-001" -AutoConfirm

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

> **规模护栏**：`protect` 会在写入前做规模预检——源目录是**安全边界根本身**或**盘根**、
> 或实测**文件数 > 5000** / **总字节数 > 500 MB** 时直接拒绝（`-AutoConfirm` 也不能绕过）。
> 唯一逃生通道是显式 `-ForceLarge`，硬闯会写 `Write-Warning` 并记入 `actions.log` 可追溯。
> 该护栏是 fail-closed 设计：拒绝时源目录零副作用（不建任何目录）。

> 上面示例用 `<你的目录>` 占位。边界默认值 `D:\15812\` 是**作者本机路径**，
> 在别的机器上通常不存在，此时必须按第 0 步显式配置。

快照轮转：每次 protect 后保留最近 N 个快照（默认 5，`-KeepSnapshots` 可调），超出删最旧。
protect 采用**先写临时目录、成功后原子 rename** 的提交方式——中断（Ctrl+C / 崩溃 / 磁盘满）
只会留下一个被 history 和轮转忽略的 `*.tmp` 残骸，不会污染快照序列。

## 目录布局（两种模式）

**默认模式**（不传 `-SnapshotRoot`，与旧版一致）——快照与状态都在被保护目录内：

```
<Source>\
├─ .freeze\                        # state.json + actions.log
│  ├─ manifests\<ts>.json          # 每个快照的 SHA256 清单（集中存放，按 ts 一一对应）
│  ├─ link-<卡号>.json              # 卡↔快照绑定（protect -Card 写入，融合期 1）
│  └─ prerestore-*\                # restore 前自动备份（默认保留最近 3 份，-KeepBackups 可调）
└─ .freeze-snap\
   ├─ snap-<yyyyMMdd-HHmmss>\      # 快照镜像（每次 protect 新增一个，不覆盖）
   └─ snap-<...>.tmp\              # protect 进行中的半成品（中断残留，不参与任何统计）
```

**共享库模式**（protect 时传 `-SnapshotRoot`）——快照挪到源目录之外的独立存储，
源目录内只剩 `.freeze\`（状态与清单），不再产生 `.freeze-snap\`：

```
<SnapshotRoot>\                    # 例: D:\deepfreeze-store（可与其他源不同卷）
├─ <srcKey>\                       # 源路径 SHA256 前 12 位 —— 多源隔离，snap-<ts> 不跨源撞名
│  ├─ snap-<yyyyMMdd-HHmmss>\
│  └─ snap-<...>.tmp\
└─ <srcKey2>\                      # 另一个源的快照（互不可见）
```

- 快照位置记在 `<Source>\.freeze\state.json` 的 `snapshot_root` 字段（每次 protect 写入实际使用的目录）；
  `restore`/`status`/`history`/`unprotect` 从它读回，旧版 state.json 无此字段时回落默认位置（向后兼容）。
- **不要把 `-SnapshotRoot` 指到被保护源目录内部**——那会退化为「快照套快照」滚雪球，等价于当年被删除的 junction 方案。
- `unprotect -Purge` 会清空**本源**在共享库下的快照目录（`<SnapshotRoot>\<srcKey>`），不影响同库其他源；
  若源目录残留迁移前落在默认位置的旧快照，也会一并清理。

清单**刻意不放进快照目录**：restore 的 `robocopy /MIR` 源是快照目录，清单若在其中会被
原样拷回源根（自我污染，实测复现过的 bug），且快照越多泄漏越多。清单移到 `.freeze\manifests\`
后该目录已在 `/XD` 排除列表内，双向干净。

## 与 agent-covenant 的衔接（期 1）

deepfreeze 与 `agent-covenant` 的融合分四期，**当前只落地期 1**——建立「任务卡 ↔ 快照」绑定，
使任意卡号能查到开卡前的快照。两仓各写各的字段，**零代码耦合**（不 import、不互相调用）。

`protect -Card <卡号>` 成功后写 `<Source>\.freeze\link-<卡号>.json`（`.freeze\` 已被本仓
`.gitignore` 排除，且在 robocopy `/XD` 排除列表内，**不会**被拷进快照）：

| 字段 | 含义 |
|---|---|
| `card` | 卡号（与文件名一致） |
| `snap_ts` | 本次快照时间戳（`yyyyMMdd-HHmmss`） |
| `snap_path` | 快照目录**绝对路径**（共享库模式下在源目录外，故记绝对路径） |
| `snapshot_root` | 本次实际使用的快照根 |
| `source` | 被保护的源目录 |
| `created_at` | 写入时刻 `yyyy-MM-dd HH:mm:ss` |

- **写入时机**：快照提交成功、`state.json` 落盘之后，快照轮转之前。
- **重复 protect 语义**：同卡号第二次 `protect -Card` 覆盖同一文件的 `snap_*` 字段（最新快照胜出），
  `created_at` 同步更新；不报错、不追加历史。
- **不带 `-Card`**：完全不碰 link 目录，行为与旧版逐位一致（兼容性红线）。
- **卡号校验**：须匹配 `^[A-Z]{2,6}-\d{8}-\d{3}$`，否则 `throw` 拒绝（fail-closed，校验排在
  任何写操作之前，拒绝时源目录零副作用）。
- **回滚安全隔离（D3）**：快照轮转删除旧快照**目录**时，若某 `link-*.json` 仍引用其 `snap_ts`，
  该快照的 **manifest 跳过删除**（目录与清单解耦，清单仅数 KB，保住门禁回滚所需清单）。
  若 link 文件损坏（非法 JSON / 缺 `snap_ts`），按 **fail-closed** 保守处理：**不删任何 manifest**，
  并 `Write-Warning` 提示「manifest 轮转已暂停」。
  ⚠️ **已知债务（期 1）**：坏 link 会让 manifest **只增不减**（上界无界）。触发时 protect 会告警，
  需**人工修复** `.freeze\link-*.json` 后重跑 protect 才恢复轮转；自动化清理留待后续期次。
- **link 写入失败**：快照提交成功但 link 写失败（磁盘满/权限）时，`protect` **非零退出**
  （不静默断裂可追溯链），`state.json` 标记 `linked:false`，错误信息给出「重跑 protect -Card 补写」的恢复路径。
  不带 `-Card` 的 protect 不写 `linked` 字段，`state.json` 形状与旧版**逐位一致**（兼容性红线）。

期 2（covenant 门禁读 link 校验）、期 3（派卡自动 protect）、期 4（FAIL 自动回滚）**均未实现**，
不在本工具范围。

## 安全设计

| 机制 | 说明 |
|---|---|
| 路径边界 | 仅允许 `$AllowedRoot` 下目标；**链接（junction/symlink）按真实目标判定**，指向界外一律拒绝 |
| 规模护栏 | `protect` 前置规模预检：源=边界根/盘根、文件数 > 5000 或总字节 > 500 MB 一律 **throw 拒绝**（fail-closed），`-AutoConfirm` 不能绕过（2026-10-03 两次整盘事故的触发路径就是 `-AutoConfirm`）；唯一逃生通道 `-ForceLarge`，硬闯记入 `actions.log`。阈值只定义在 `deepfreeze.ps1` 的 `Test-SourceScale` 一处 |
| 边界配置 | 解析顺序：`-AllowedRoot` → 环境变量 `DEEPFREEZE_ALLOWED_ROOT` → 默认 `D:\15812\`（仅当该路径存在时）。三者都拿不到则**拒绝启动**——刻意 fail-closed，不猜一个宽边界兜底。换机器/换用户请显式配置 |
| 越界双确认 | 越界路径除 `-Force` 外还需 ShouldContinue 二次确认 |
| 还原前备份 | restore 前自动打 `prerestore-<时间戳>`，默认保留最近 3 份（`-KeepBackups` 可调） |
| 快照原子性 | protect 先写 `*.tmp` 临时目录，全部成功后同卷 rename 提交；半成品不进 history、不计轮转 |
| 哈希校验 | restore 后按 manifest 逐文件校验；**文件被锁计入漂移并明确报出**，不会半路崩溃（throw 终止，不用 exit N，不杀调用方 shell） |
| 拒绝裸奔 | 未 protect 时 restore 直接抛错拒绝；快照全部缺失同样拒绝 |
| 确认门槛 | protect/restore/unprotect 走 Test-Gate（ShouldProcess 支持 -WhatIf + ShouldContinue 必弹确认）；`-AutoConfirm` 供脚本跳过 |
| 快照根与源解耦 | `-SnapshotRoot` 可把快照放到与源**不同卷**的独立存储（源在 C 盘项目、快照落 D 盘），工具不再需要手工 junction——边界外的快照库不会被 robocopy `/XD` 当普通目录拷进快照，杜绝滚雪球。共享库按 srcKey 隔离多源；`-SnapshotRoot` 仅 protect 接收，其余子命令从 `state.json` 读回。该参数**不做路径边界校验**（显式传参即责任自负，实际落点会 `Write-Warning` 明示），但**不放宽规模护栏**——护栏拒绝的永远是"源太大"，与快照存哪无关 |

## 自检

```powershell
.\verify.ps1
# 核心 正/负路径 + T1锁文件 / T2快照缺失 / T3备份轮转 / T4 Unicode名 / T5 junction穿透 / T6 purge重保护
# + N1清单不泄漏 / N2清单不自包含 / N3多快照 / N4 history / N5指定快照还原 / N6默认还原最近 / N7快照轮转 / N8 .tmp隔离
# + G1~G6 规模护栏（边界根/盘根/超文件数/超字节被拒、-ForceLarge 逃生留痕、正常目录不误杀）
# + H1~H7 快照根可配（默认落点回归 / 共享库落点 / state.json 持久化 / 多源 srcKey 隔离 /
#   旧 state.json 向后兼容 / store 自动创建 / 护栏不因 -SnapshotRoot 放宽）
# + P1~P3 manifest 性能改造（List 化后形状与哈希逐位不变 / diff 分类不变 / history 流式计数）
# + Q1~Q6 格式守卫 + ForceLarge 空间警告（紧凑单行格式被 history 拒绝报"格式异常" /
#   空 manifest 不误判 / -ForceLarge 默认落点空间警告 / 同卷 -SnapshotRoot 警告不回归 /
#   正常 protect 不弹空间警告）
# + C1~C11 卡号绑定 + link 安全（protect -Card 合法卡号写 link / link 字段完整且 snap_path 绝对路径真实存在 /
#   非法卡号 fail-closed 且零副作用（含大小写敏感 / 仅 ASCII 数字 / 尾部换行三处正则绕过面）/ 不带 -Card 不产 link /
#   同卡重复 protect 覆盖 snap 字段 / 轮转不删被引用 manifest / 共享库模式 link 落源目录 / link 不进快照 /
#   非 protect 子命令带 -Card 不报错 / link 写入失败时 protect 非零退出且 state.json 标记 linked:false /
#   坏 link 触发 BlockAll 警告且 manifest 只增不减）
# PASS = exit 0（断言总数见脚本尾部输出：96 项基线 + 50 项 C 系断言 = 146 项）
```

> **负载敏感项与重试策略（DFB-20261021-001 加固，DFB-20261021-003 收尾）**：T2（删快照）与 G4（525MB 写盘）
> 是全自检最重的 I/O 项，机器负载高时偶发失败（多轮观测：基线 5 次 1 挂，T2/T4/G4/H8
> 随机出现）。加固后：T2 删后确认清零 + 短重试（残留会告警说明，环境类现象可诊断）；
> G4 夹具写入失败允许一次重试；H8 夹具自足化（自建"两源一库"，不再依赖 H4 现场，级联消除）；
> **Q2 的报错消息断言容时序**（stderr 的 ReadToEndAsync 与进程退出存在竞态，截断时重跑一次
> 再匹配——真失败重跑后仍缺，不被吞）；**H4 的精确计数断言改隔离语义加强**
> （每 srcKey 快照数 ∈ {1,2} + 两侧互异——混写会让计数冲出集合或两侧相等，比总数断言
> 对「无混写」不变量的保护更强）；所有子进程调用带 120s 超时 watchdog + 环境类失败一次重试。
> **重试只针对环境类失败**（超时/负载 IO/非零退出），语义类失败（断言判定为假，如 restore 本该拒绝却成功）
> 绝不重试、立即判死——fail-closed 保留。

> ⚠ **开发者约束**：manifest 必须保持 `ConvertTo-Json -Depth 5` 的**多行缩进格式**——
> `history` 的流式计数依赖「`files` 键独占一行」。改成 `-Compress` 后 `history` 会直接
> `throw`「manifest 格式异常」（fail-closed，不会静默给出错误计数）；两种出路见该报错信息，
> 并同步更新 verify 的 Q 系断言与本文档此条。

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
   触发仍为手动，但 `protect` 支持 `-Card` 记录「卡 ↔ 快照」绑定（融合期 1，期 2/3/4 未实现）。
6. **不防多时间点之间的外部状态漂移**——只认文件内容，不认「世界」。
7. **坏 `link-*.json` 会让 manifest 轮转暂停（期 1 已知债务）**——为保住门禁回滚所需的清单，
   检测到损坏 link 时按 fail-closed **不删任何 manifest**（会 `Write-Warning` 告警），
   结果是 manifest 目录**只增不减**、上界无界，需**人工修复** 损坏的 `.freeze\link-*.json`
   后重跑 protect 才恢复轮转。自动化坏-link 清理/隔离留待后续期次。

若将来确实需要「真·冰点」：唯一现实的下一阶段是 Hyper-V 差分磁盘 checkpoint
（整机进 VM，Windows 自带差分磁盘做整机快照，无需写驱动）。本工具不涉及此方向。

## 路线图（写在前面免得误解）

1. **接入 agent hook —— 危险操作前自动 protect**。这是把本项目从「手动工具」变成
   「agent 基础设施」的关键一步，也是与 `agent-undo` / `agent-rollback` 类工具的差异点。
   ✅ **已落地（期 3，DFB-20261021-002）**：OpenCode 插件 `deepfreeze-autosnap`
   （节流形态，见「宿主集成」节）——写类工具执行前自动 protect，10 分钟窗口节流，
   fail-open（protect 失败绝不阻断写操作）。卡号绑定仍由 `protect -Card` 派卡纪律承载（期 1）；
   期 2 门禁读 link 已闭环。
2. **Linux/macOS 支持**——需重写文件操作层（去掉 `robocopy` 依赖），成本高，优先级低。
3. **条件触发快照**（如「目录变更超过 N 个文件时自动 protect」）——节流窗口是它的一种形态
   （期 3 已落地）；更细粒度的文件监听层仍缺。

其他边界：

- 保护对象是**普通数据目录**；`/MIR` 会删目标里快照后新增的文件——这是特性不是 bug，但被保护目录别当垃圾场
- `prerestore-*` 备份与快照是两套东西：快照是「回到某个时间点」，prerestore 是「还原出错时退回还原前」，语义不同，不合并
- 规模护栏挡的是「合法但危险」的调用（整盘/边界级 protect），不挡正常项目目录；`-ForceLarge` 是给「我就是知道它很大、我就是要保护」的场景留的显式出口，不是常规参数

## 宿主集成（OpenCode 插件 · 期 3，DFB-20261021-002）

`deepfreeze-autosnap` 插件挂在 OpenCode 的 `tool.execute.before` 上：agent 的写类工具
（edit/write/patch）执行前，自动对目标项目根调一次 `protect`。**这是「agent 一动手就
有新鲜快照」的落地形态**——但请如实理解它的边界：

- **节流，不是每次写都拍**：状态持久化在 `<项目根>\.freeze\autosnap-state.json`（原子写），
  同目录 10 分钟窗口（`DEEPFREEZE_AUTOSNAP_WINDOW_SEC` 可调）内只拍一次。保障粒度 =
  **窗口起点**——连续改 20 个文件，中途改坏只能 restore 回窗口起点（前序好改动一并回滚），
  这是「后悔药」语义的固有代价，不是逐步回滚。
- **fail-open，绝不阻断写操作**：protect 失败（规模护栏拒绝/超时/任何错误）只 `console.warn`，
  写操作照常执行，且失败会重置窗口槽（下一次写立即重试）。**快照是后悔药，不是门禁**——
  fail-closed 是 agent-covenant 的 gate 的职责，两者分工不同。
- **无 `--Card`**：插件的快照不绑定任务卡（无 link 文件）——LINK_NOT_STAMPED 不会误报
  （它只在「link 存在但未回写」时触发），restore 也不需要 link。卡号绑定仍由派卡时的
  `protect -Card <卡号>` 纪律承载（期 1）。
- **多会话并发**：节流状态持久化共享；两个会话同时撞进窗口可能双拍——快照只追加不覆盖，
  多一份只费磁盘，不损正确性。

**配置**（全部可选，插件路径 `~/.config/opencode/plugins/deepfreeze-autosnap.js`）：

| 环境变量 | 作用 | 默认 |
|---|---|---|
| `DEEPFREEZE_SCRIPT` | deepfreeze.ps1 绝对路径（**必填**，不设则插件惰性并告警一次） | —— |
| `DEEPFREEZE_AUTOSNAP_ROOTS` | 分号分隔的项目根白名单 | 未设 = 仅当前会话的 worktree |
| `DEEPFREEZE_AUTOSNAP_TOOLS` | 写工具名的正则 | `^(edit\|write\|patch)` |
| `DEEPFREEZE_AUTOSNAP_WINDOW_SEC` | 节流窗口秒数 | 600（10 分钟） |

白名单解析顺序：环境变量 → 项目根的 `.deepfreeze-autosnap` 标记文件（存在即启用）→
默认仅当前会话的 worktree。换机器/新项目目录用前两个配置，不硬编码。

自测：`bun tools/autosnap-selftest.mjs`（8 场景：触发/节流/窗口过期/非写工具/白名单外/
fail-open/失败后重试/状态原子性——走真实 PowerShell 子进程，非 mock 内部）。

## 文件

| 文件 | 角色 |
|---|---|
| `deepfreeze.ps1` | 主脚本 |
| `verify.ps1` | 自检 |
| `tools/autosnap-selftest.mjs` | 期 3 插件的验收测试（bun 跑） |
| `_selftest\` | 自检夹具（自动重建，已 gitignore） |
