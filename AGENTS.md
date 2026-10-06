# AGENTS.md — deepfreeze 项目上下文

> 本文件是 deepfreeze 的**项目根上下文**。所有 agent 在本项目动手前先读它。
> 与私有记忆冲突时，**以本文件为准**。

## 项目是什么

`deepfreeze` — 仿 Windows「冰点还原」的**目录级**快照/还原工具（PowerShell 5.1，零依赖）。

| 文件 | 作用 |
|---|---|
| `deepfreeze.ps1` | 主体。子命令：`protect` / `restore` / `status` / `history` / `unprotect` |
| `verify.ps1` | 自检套件。**87 项断言**（39 项基线 N1~N8 + T1~T6，+ 13 项 G 系规模护栏，+ 27 项 H 系 SnapshotRoot 含 H8 purge 孤儿清理边界，+ 8 项 P 系 manifest 性能改造）。退出码 0 = PASS |
| `README.md` | 用户文档 |

核心能力：**多时间点快照**（每次 `protect` 追加一个 `snap-<yyyyMMdd-HHmmss>`，不覆盖）。

## 当前基线（2026-10-05 核实）

```powershell
# ⚠️ 不要在本文件里 hardcode HEAD —— 任何更新基线的提交本身就会让那个值过期，
#    形成「改一次过期一次」的追赶循环（同 recurring-pitfalls 坑 15）。现场读：
git rev-parse --short HEAD
git status --short          # 必须空
```

| 门禁 | 命令 | 最近实测 |
|---|---|---|
| `verify.ps1` | `powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1` | **PASS (87 项断言)** EXITCODE=0 |
| `lint_cards` | `python ...\lint_cards.py --dir .tasks --verdict-dir verdicts` | **PASS (0 warnings)** |
| `gate.py` | `python ...\gate.py --verdict-dir .tasks\archive --artifact-map artifacts.json` | **PASS (3 checked: 1 PASS + 2 SUPERSEDED 不阻塞)** |

三仓库并行开发时的冲突面见文末。

### ✅ 门禁已真正生效（2026-10-05 修复）

此前 `gate.py` 的「PASS」是**假的**——两个独立原因叠加：

1. **verdict 目录指向空处**。DFB-20261004-001 归档后 `verdicts\` 已空，日常命令 `--verdict-dir verdicts` 实际检查 **0 个 verdict**（带 `--require` 时直接 `MISSING_VERDICT` FAIL）。
2. **没有 `artifacts.json`**，`freshness NOT checked`——verdict 失效不会被拦。

现两处都已修，命令见「二、5 改完跑门禁」。**已双向验证**（非只验通过路径）：

| 测试 | 期望 | 实测 |
|---|---|---|
| 正向：现状 | PASS | ✅ PASS (3 checked) |
| **反向：把 README.md mtime 推到当前** | 必须报 STALE | ✅ `[STALE_VERDICT] ... 2026-10-05T08:14 > 2026-10-04T12:03`，EXIT=1 |
| 还原 mtime 后 | 恢复 PASS | ✅ PASS (1 checked) |

DFB-20261003-001 / -002 的 artifact 早已被 004-001 重新判定，gate 正确降级为 `SUPERSEDED`（不阻塞）。

**维护提醒**：新增 verdict 后必须同步在 `artifacts.json` 加条目，否则该 id 又退回「不检查」。理由写在 `artifacts.json` 的 `_scope_notes` 里。

---

## 一、禁止事项（红线，无条件执行）

### 🚫 禁止对盘根或大边界目录跑 protect

```powershell
# ❌ 绝对禁止
.\deepfreeze.ps1 protect -Source "C:\"
.\deepfreeze.ps1 protect -Source "D:\"
.\deepfreeze.ps1 protect -Source "D:\15812"
.\deepfreeze.ps1 protect -Source "D:\15812\Documents"

# ✅ 正确：只保护具体项目目录
.\deepfreeze.ps1 protect -Source "D:\15812\projects\deepfreeze" -AutoConfirm
```

**为什么**（有真实事故记录，不是理论风险）：

| 事故 | 后果 |
|---|---|
| 2026-10-03 16:51 对 `C:\` 跑 protect | 31.42 GB / 114,012 文件，跑到一半被硬杀，`.tmp` 残骸占满 C 盘 |
| 2026-10-03 17:01 对 `D:\15812` 跑 protect | 同样中断 |

**根因**：`deepfreeze.ps1` 里 `$AllowedRoot = 'D:\15812'` 这行默认边界，配合 `Test-WithinAllowed` 判据里的 `$FullPath -eq $AllowedRoot`（**源目录等于边界本身时判为「在边界内」**），使「对 `D:\15812`跑 protect」成为一次**静默通过全部校验的合法调用**。实测 `D:\15812` = **33.9 GB / 33,777 文件**，其中 `Documents` 单目录就 4.7 GB。

**保护粒度参考**（实测体积，2026-10-04）：

| 目录 | 文件数 | 体积 | 可protect |
|---|---|---|---|
| `D:\15812\projects\fish-sim` | 3 | 162 KB | ✅ 理想 |
| `D:\15812\projects\KNOWLEDGE-EXPORT` | 16 | 32 KB | ✅ 理想 |
| `D:\15812\projects`（全部） | 14,115 | 782 MB | ⚠️ 可但慢，先想清楚 |
| `D:\15812` | 33,777 | 33.9 GB | ❌ 禁止 |
| `C:\` | — | — | ❌ 禁止 |

**判断标准**：预计产出 > 500 MB 或 > 5,000 文件 → **先想清楚，别跑**。

> 以上禁止已由 `deepfreeze.ps1` 的规模护栏（`Test-SourceScale`）强制执行：源=边界根/盘根、文件数 > 5000 或字节 > 500 MB 时 `protect` 直接拒绝，`-AutoConfirm` 不能绕过；确需硬闯须显式 `-ForceLarge`，且会记入 `actions.log`（DFB-20261004-001）。

### 🚫 禁止手工建 junction 当快照库 —— 用 `-SnapshotRoot`（DFB-20261005-002）

「快照存到别的盘」现在有正式机制：`protect -Source <源> -SnapshotRoot <存储根>`，位置持久化在
`<Source>\.freeze\state.json` 的 `snapshot_root` 字段，其余子命令自动读回。**不要**再手工把快照库
放到 `-Source` 之外再 junction 回去。

**为什么 junction 是错的**：robocopy 的 `/XD` **只按路径排除** `<Source>\.freeze` 与
`<Source>\.freeze-snap`。任何路径不匹配的快照库（例：曾在用的 `D:\deepfreeze-snap`）都会被当
**普通目录整个拷进快照**，每次 protect 体积滚雪球翻倍。`-SnapshotRoot` 是工具内建的解法，
共享库按 srcKey（源路径哈希前 12 位）分目录隔离多源，`snap-<ts>` 不跨源撞名。

2026-10-04 已清理手工 junction 遗骸：`C:\.freeze-snap`（junction→`D:\deepfreeze-snap`）与目标目录均已删除。

### 🚫 禁止改动 `.gitignore` 里的评审产物条目

`.tasks/` 和 `verdicts/` 已 gitignore——**有意为之**，卡片和 verdict 含本地绝对路径和内部流程笔记，不入公开仓库。

---

## 二、开工前纪律

### 1. 确认工作区状态（历史事故：别的会话 39 秒内移动过 master）

```powershell
git log --oneline -5
git status --short     # 必须干净
git branch -vv
```

### 2. 改代码前打快照

改 **≥3 个文件** 之前，先对本项目 `protect` 打快照：

```powershell
.\deepfreeze.ps1 protect -Source "D:\15812\projects\deepfreeze" -AllowedRoot "D:\15812\projects" -AutoConfirm
```

`-Source` **必须命名传参**，不能依赖默认值。`-AutoConfirm` 跳过交互确认。

> 本项目自身已有 `.freeze` 快照（2026-10-05 起，ZCode 按纪律开工前打的基线）。**动 `deepfreeze.ps1` / `verify.ps1` 之前先确认有可用快照**：`.\deepfreeze.ps1 history -Source "$PWD"`。

### 3. 改代码走出卡流程

改 `deepfreeze.ps1` / `verify.ps1` / `README.md` 属于改代码，必须走 agent-covenant 协议：
`.tasks/DFB-<date>-<seq>.md` 四要素（Context / Deliverables / Owned files / Acceptance）→ 独立评审 → verdict。

**改调用习惯、改配置、写文档不需要出卡。**

### 4. 交付前自跑 Acceptance

**没跑过自检的卡不许递出去。** Acceptance 里每一条都是带退出码的命令，必须自己跑完并贴出真实输出。

### 5. 改完跑三门禁（全部必须跑）

```powershell
cd D:\15812\projects\deepfreeze        # ⚠️ 必须先 cd，理由见下方坑

powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1     # 必须 EXITCODE=0
python D:\15812\projects\agent-covenant\tools\lint_cards.py --dir .tasks --verdict-dir verdicts

# gate 必须跑两次——两个 verdict 目录都要查（2026-10-05 修正）
python D:\15812\projects\agent-covenant\tools\gate.py --verdict-dir verdicts      --artifact-map artifacts.json
python D:\15812\projects\agent-covenant\tools\gate.py --verdict-dir .tasks\archive --artifact-map artifacts.json
```

#### ⚠️ gate.py 必须查**两个** verdict 目录

`--verdict-dir` 只接受**单个**目录，而本项目的 verdict 分两处：

| 目录 | 内容 |
|---|---|
| `verdicts\` | **活跃卡**的 verdict（`IN_REVIEW`/`RETURNED` 阶段） |
| `.tasks\archive\` | 已归档卡的 verdict（`GATED`/`CLOSED` 后与卡成对移入） |

**只跑 `--verdict-dir .tasks\archive` 会完全看不见活跃卡的 verdict。** 2026-10-05 实测：`DFB-20261005-002` 的 `CONDITIONAL` 落在 `verdicts\`，只查 archive 时**一条都看不到**。

**后果**：条件未清的卡会被静默放过——正是本会话一直在修的那类盲区。

#### ⚠️ 活跃区出现 CONDITIONAL 时会 FAIL

```
[CONDITIONAL_NOT_ALLOWED] DFB-20261005-002: CONDITIONAL requires --allow-conditional
```

这是**预期行为**：条件没清完就不该放行。**不要**用 `--allow-conditional` 绕过——先处理 condition。真要放行必须 sir 明确批准，且在交付说明里写明依据。

#### ⚠️ 旧 verdict 的 STALE 要等新 verdict 归档才消解

`_successeded_by` 机制**只在 successor verdict 位于同一目录时生效**。新卡 verdict 在 `verdicts\` 时，它无法接管 archive 里旧卡对同一批文件的判定——旧 verdict 仍报 STALE。

**STALE 转 SUPERSEDED 的时点**：新卡走完 `GATED` → 卡与 verdict **成对移入 `.tasks\archive\`** 之后。

#### ⚠️ gate 必须在 deepfreeze 目录内跑

`artifacts.json` 里的路径是**相对路径**，相对**进程 CWD** 解析。在仓库根（或任何别处）跑会 `ARTIFACT_MISSING` 误报。

---

## 三、遗留问题与当前状态（2026-10-04 核实）

### ✅ 已解决

| 项 | 处置 |
|---|---|
| `C:\.freeze-snap` junction → `D:\deepfreeze-snap` | 已删（链接 + 目标），滚雪球隐患消除 |
| `C:\.freeze` / `D:\15812\.freeze` 残骸 | 已删（两次中断的 protect 现场，证据已留档） |
| 7 张卡 5 种终态并存 | 已全部物理移入 `.tasks/archive/`（含 2 份配套 verdict） |
| `PROBE-README.md`（Ximo 时代死文件） | 已删 |
| `Desktop\.freeze-snap` / `D:\15812\.freeze-snap` 空壳 | 已删 |
| `AGENTS.md` 本文件 | 已建 |

commit：`fd24c26`。lint 从 **8 warnings → 0 warnings**（8 条全部消解：2 条 `CLOSED_NOT_ARCHIVED` + 5 条 `VERDICT_WITHOUT_REVIEW` 随卡归档消解，1 条 `TASK_MISSING_REVIEW_QUESTIONS` 由新卡补齐段落）。

### 目录布局约定（改动后）

```
.tasks\                      ← 活跃卡（lint 的 --dir 指向这里）
  DFB-<date>-<seq>.md
  archive\                   ← 已归档卡 + 各自 verdict（不再参与活跃 lint）
verdicts\                    ← 活跃卡的 verdict 落点（当前为空）
```

**注意**：那 8 个 20261003 卡在 `.gitignore` 规则生效前就已被 commit，所以 ignore 规则对它们无效。`fd24c26` 提交其删除后才真正 untrack——这实现了 `.gitignore:3` 注释写明的原意。`archive/` 下的副本被 ignore，本地完整保留。

**归档约定**：卡进入 `GATED`/`CLOSED` 后 1 个工作日内，卡与配套 verdict **成对移入 `.tasks\archive\`**。已归档 11 项（8 张 20261003 卡 + REVIEW 单 + 2 份 verdict + `DFB-20261004-001` 卡与 verdict）。

### ⚠️ linter 已知缺口（属 agent-covenant 会话，非本项目）

`lint_cards.py` 没有「归档目录」概念：对 `.tasks\archive\` 跑 lint 会对已归档的 CLOSED/GATED 卡照样报 `CLOSED_NOT_ARCHIVED`。**所以 lint 只能对 `.tasks\` 跑，`archive\` 不跑。** 若要根治需 covenant 侧加 `--archive-dir`，已记录待会话 C 处理——**本项目不得改 covenant**。

### 进行中

| 卡 | 状态 | 内容 |
|---|---|---|
| `DFB-20261005-002` | `IN_REVIEW` | `-SnapshotRoot` 快照存储位置可配。ZCode 交付 `d5c03ef`，主控已独立复核（72/72 PASS、护栏未动），待 AgnesCode 评审 |
| `DFB-20261005-003` | `IN_REVIEW` | manifest 内存/时间优化四处。ZCode 交付 `7ccbd10`，主控已独立复核（87/87 PASS、护栏零触碰、哈希第三方比对逐位一致），待 AgnesCode 评审 |

**最近完成**：`DFB-20261004-001`（protect 规模护栏）— verdict `PASS`（round 2，0 blocker + 0 condition），已上线。

### 留作后续 EVO 的开放项

| 维度 | 内容 | 出处 |
|---|---|---|
| 排除语义统一 | `Get-ProtectedFiles` 用 `-notlike "$Root\.freeze\*"`（**前缀**匹配）vs robocopy `/XD`（**路径精确**排除）。理论分叉仅在 `.freezeX` 这类恰好前缀命中的目录名，实际场景不存在 | 评审维度 5 |
| verify 降本 | `verify.ps1` 每次跑写 5001 文件 + ~525MB，墙钟 **~72s**，相对秒级基线是数量级退化。判定可接受，建议改稀疏文件/不落盘构造 | 评审维度 6 |
| **S1**（DFB-20261005-002 后续） | `-ForceLarge` 不传 `-SnapshotRoot` 时（默认落点 `<Source>\.freeze-snap` 天然同卷）无「正在吃满源卷」空间警告。C2 已覆盖 `-SnapshotRoot` 同卷路径，但默认落点未补。建议一行 `Write-Warning` 补齐。**预存缺口，非本卡引入，不阻塞** | R2 评审 S1 |

（原先第三项「verdict 新鲜度」已于 2026-10-05 修复，见「当前基线」下的小节。）

---

## 四、会话边界（硬约束，优先于其他一切）

### 本会话只负责 deepfreeze

**主控 agent 在本会话中不得对下列项目做任何写操作**（不改文件、不跑服务、不杀进程、不提交）：

| 项目 | 归属会话 |
|---|---|
| `D:\15812\Documents\deepseek-brain` | 会话 B |
| `D:\15812\projects\agent-covenant` | 会话 C |
| 其余一切非deepfreeze 仓库 | 其他会话 |

**允许的只有只读观察**，且仅限两种用途：
1. 检测与本项目的冲突面（见下节）
2. 本项目门禁需要调用 `agent-covenant\tools\*.py`（只读调用，不改）

**明确禁止**：即使发现问题也不要顺手修。即使对方进程看起来是死的/跑的是旧代码，也不要动。**"它坏了"不是越界的理由**——那是对方的会话负责判断和处理的事。

> 2026-10-04 记录：曾因 `deepseek-brain` 的 shim 报 `bridge_idle` 而主动重启该进程（kill PID 40972 + 起新进程 42608）。**这是越界。** 该项目的进程生命周期归会话 B 所有，本会话只应观察并向 sir 报告，不应动手。

### 三仓库并行的冲突面（只读监控）

同开三个会话时的真实耦合点，**只有两处**：

### ① 共享 agent-covenant 工具（唯一真冲突面，只读）

`D:\15812\projects\agent-covenant\tools\lint_cards.py` 和 `gate.py` 被本项目引用。

- 本项目**只读调用**，不改 covenant 任何文件。
- 若另一会话正在改 `tools/*.py`，本项目的门禁结论可能基于半成品代码。
- **动作前核对**：跑门禁前先 `git -C D:\15812\projects\agent-covenant log --oneline -1`。若 HEAD 与上次记录不符，在本项目 AGENTS.md 或交付说明里标注「门禁基于 covenant HEAD `xxxx`，该会话可能正在修改」，**不要自己去改 covenant 或要求对方停工**。

### ② deepfreeze 卡片依赖 covenant 的 verdict schema（逻辑耦合）

DFB-002 若需重签 verdict，schema 必须与当前 covenant 一致。

### 无冲突

三仓库 git 工作区互不相干；本项目不依赖另外两个仓库。

---

## 五、协作角色

| Agent | 角色 | 边界 |
|---|---|---|
| **OpenCode**（主控） | 主力实现 + 出卡者（`DFB-` 前缀）、项目上下文维护 | 不自审自己写的卡 |
| **ZCode** | 重装主攻（大型/多模块实现） | 同为出卡者，实现侧 |
| **AgnesCode** | 独立评审 + 侦察兵 | 只读卡 → 写 `verdicts/DFB-*.json` + verdict，**不改作者文件** |

**评审纪律**（2026-10-03 沙箱清空事故后固化）：
- 评审文档和 verdict **必须直接贴进回复**，不能只给路径。
- verdict 与评审文档**同批交付**。

---

## 六、代码事实备忘（别重复查）

**用函数名/代码模式定位，不要写行号。** 行号会随每次改动漂移——本表曾因 DFB-20261005-002 插入 60 行而全部失准。行号与 HEAD 同属不稳定锚点（同 recurring-pitfalls 坑 15）。

| 锚点（函数名 / 代码模式） | 事实 |
|---|---|
| `function Test-WithinAllowed` | 边界判定。注意其判据含 `$FullPath -eq $AllowedRoot`——**这一项正是整盘事故的根因**，规模护栏（`Test-SourceScale`）已补上兜底 |
| `function Resolve-SourcePath` | 解析 + 链接真实目标判定；越界需 `-Force` + 二次确认 |
| `$AllowedRoot = 'D:\15812'` | 默认边界（`Resolve-SourcePath` 之前）。实测 `D:\15812` = 33.9 GB / 33,777 文件 |
| `$DefaultSnapRoot = Join-Path $Source '.freeze-snap'` | **不传 `-SnapshotRoot` 时**的快照落点 |
| `$SnapRoot = Join-Path $store (Get-SrcKey -Path $Source)` | **传了 `-SnapshotRoot` 时**的落点；`Get-SrcKey` = 源路径 SHA256 前 12 位 |
| `$ManifestsDir = Join-Path $StateDir 'manifests'` | 清单集中存放 —— 防止 restore 时 `/MIR` 污染源目录造成自我拷贝 |
| `function Get-SnapshotManifestPath` | 按 ts 查清单。**多源共用 SnapshotRoot 时 srcKey 隔离就是为它服务的**——撞名会取到别人的清单 |
| `'/XD', (Join-Path $Source '.freeze'), (Join-Path $Source '.freeze-snap')` | robocopy 排除**只按路径**。快照库路径不匹配就会被整个拷进快照 → 滚雪球。这是手工 junction 被禁的原因 |
| `function Invoke-RobocopyMirror` | 封装 robocopy；exit ≥16 致命、=8 部分失败继续由哈希校验判定 |
| `function Remove-OldSnapshots` | 轮转，默认 `-KeepSnapshots 5` |
| `function Get-Sha256Hex` | 已改**流式**：`File.Open(..., FileShare.Read)` + `ComputeHash(Stream)`，驻留与文件大小解耦（原 `ReadAllBytes` 整文件进内存）。`FileShare.Read` 保持原打开语义——被独占锁定的文件照旧抛错走 `[漂移-不可读]`（T1 行为不变）。P1 断言用 `Get-FileHash` 第三方参照锁定逐位一致 |
| `function Get-ProtectedFiles` | 排除 `.freeze` / `.freeze-snap`，用 `-notlike "$Root\.freeze\*"` **前缀**匹配（与 robocopy 精确排除理论分叉，见开放项） |
| `function Test-SourceScale` | 规模护栏。阈值常量定义在**函数体顶部**（`$FileCountLimit` / `$ByteLimit`），调整只改一处 |
| `function Get-Diff` | 基于 size 的快速 diff（权威判定仍是 restore 后的哈希校验）。已 `List[string]` 化——**不再**用 `+=` 在循环里累加（原 O(N²)）。调用方 `restore` / `status` 只用 `.Count`，契约键 `New/Changed/Missing/Total` 不变 |
| `function Get-Manifest` | 已 `List[object]` 化——**不再**用 `$manifest.files += [ordered]@{...}`（原每次 protect 跑，30k 文件实测 29,113ms → 1,301ms）。`ToArray()` 后入表以保 JSON 形状逐字节不变 |
| `ConvertTo-Json -Depth 5`（`function Get-Manifest` 内） | **manifest 必须保持多行缩进格式**：`history` 流式计数依赖「`files` 键独占一行」；改成 `-Compress` 会被 `history` 的格式守卫 `throw` 拒绝（fail-closed，DFB-20261006-004，Q 系断言锁定）。空 manifest（`"files": []`）同样命中哨兵行，不误判 |
| protect 分支的 `.tmp` → `Move-Item` | 原子提交：先拷 `.tmp`，全成功才 rename 成 `snap-<ts>` |
| `if ($SnapRoot -ne $DefaultSnapRoot`（unprotect -Purge 分支） | 孤儿清理：快照迁共享库后，purge 顺带清**本源**默认位置遗留快照；同 store 其他 srcKey 不碰、actions.log 保留 —— **H8 断言锁定**（评审返工 C1） |
| `verify.ps1` 里的 `$env:DEEPFREEZE_ALLOWED_ROOT = $Root` | 自检把边界钉到仓库自身，所以每次自检都真实走到该配置路径 |

**事故机制辨析**（两次中断机制不同，根因相同）：
- **无 `.tmp` 残骸** → 进程正常抛错退出，catch 跑完了 → 预期行为
- **留下 `.tmp` 残骸** → 进程被硬杀（OOM/手动 kill），catch 没来得及跑

---

## 维护者

主控：OpenCode（jarvis@deepfreeze）
本文件最后核实：2026-10-04
