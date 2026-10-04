# AGENTS.md — deepfreeze 项目上下文

> 本文件是 deepfreeze 的**项目根上下文**。所有 agent 在本项目动手前先读它。
> 与私有记忆冲突时，**以本文件为准**。

## 项目是什么

`deepfreeze` — 仿 Windows「冰点还原」的**目录级**快照/还原工具（PowerShell 5.1，零依赖）。

| 文件 | 作用 |
|---|---|
| `deepfreeze.ps1` | 主体。子命令：`protect` / `restore` / `status` / `history` / `unprotect` |
| `verify.ps1` | 自检套件。39 项断言（N1~N8 + T1~T6）。退出码 0 = PASS |
| `README.md` | 用户文档 |

核心能力：**多时间点快照**（每次 `protect` 追加一个 `snap-<yyyyMMdd-HHmmss>`，不覆盖）。

## 当前基线（2026-10-04 核实）

```
HEAD      79153bc  docs(review): close DFB-007 (GATED)
git status 干净
verify.ps1  39/39 PASS  EXITCODE=0
lint_cards  PASS (8 warnings, 0 errors)  ← 8 个 warning 全是卡片生命周期问题，见下
```

三仓库并行开发时的冲突面见文末。

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

**根因**：`deepfreeze.ps1:60` 的默认边界是 `D:\15812`，而 `D:\15812` 实测 **33.9 GB / 33,777 文件**，其中 `Documents` 单目录就 4.7 GB。默认边界允许对边界内**任何目录**（含边界本身）跑 protect，所以「合法调用」也能造成灾难。

**保护粒度参考**（实测体积，2026-10-04）：

| 目录 | 文件数 | 体积 | 可protect |
|---|---|---|---|
| `D:\15812\projects\fish-sim` | 3 | 162 KB | ✅ 理想 |
| `D:\15812\projects\KNOWLEDGE-EXPORT` | 16 | 32 KB | ✅ 理想 |
| `D:\15812\projects`（全部） | 14,115 | 782 MB | ⚠️ 可但慢，先想清楚 |
| `D:\15812` | 33,777 | 33.9 GB | ❌ 禁止 |
| `C:\` | — | — | ❌ 禁止 |

**判断标准**：预计产出 > 500 MB 或 > 5,000 文件 → **先想清楚，别跑**。

### 🚫 禁止手工创建 `.freeze` / `.freeze-snap` 在边界外

`.freeze-snap` 的位置由 `deepfreeze.ps1:127` 从 `-Source` 推导，**不要**手工把快照库放到 `-Source` 之外再 junction 回去。

**为什么**：`deepfreeze.ps1:207` 的 robocopy `/XD` **只排除** `<Source>\.freeze` 和 `<Source>\.freeze-snap`。任何路径不匹配的快照库（例：曾在用的 `D:\deepfreeze-snap`）都会被当**普通目录整个拷进快照**，导致每次 protect 体积滚雪球翻倍。

2026-10-04 已清理：`C:\.freeze-snap`（junction→`D:\deepfreeze-snap`）与目标目录均已删除。

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

> 本项目自身目前**没有** `.freeze` 快照（历史遗留，2026-10-04 核实）。首次开工时先打一份基线快照。

### 3. 改代码走出卡流程

改 `deepfreeze.ps1` / `verify.ps1` / `README.md` 属于改代码，必须走 agent-covenant 协议：
`.tasks/DFB-<date>-<seq>.md` 四要素（Context / Deliverables / Owned files / Acceptance）→ 独立评审 → verdict。

**改调用习惯、改配置、写文档不需要出卡。**

### 4. 交付前自跑 Acceptance

**没跑过自检的卡不许递出去。** Acceptance 里每一条都是带退出码的命令，必须自己跑完并贴出真实输出。

### 5. 改完跑双门禁

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1     # 必须 EXITCODE=0
python D:\15812\projects\agent-covenant\tools\lint_cards.py --dir .tasks --verdict-dir verdicts
```

---

## 三、已知遗留问题（2026-10-04 核实）

### P1 · 卡片生命周期烂账

7 张卡 5 种终态并存，无一归档，`.tasks/archive/` 目录**根本不存在**。

| 卡 | 状态 | 待处理 |
|---|---|---|
| DFB-001 | `CLOSED` | 超期未归档（PROTOCOL §8 要求 1 个工作日内） |
| DFB-002 | `REVIEW-REQUESTED` | verdict 已在库，卡状态未同步；A4 fail-closed 未实测 |
| DFB-003 | `RETURNED-TO-REVIEWER` | 实际已被 DFB-007 取代，未销账 |
| DFB-004 | `RETURNED-TO-REVIEWER` | 同上 |
| DFB-005 | `RETURNED-TO-REVIEWER` | 同上 |
| DFB-006 | `RETIRED-FACTUAL-ERROR` | 已作废，仍占位 |
| DFB-007 | `GATED` | 超期未归档 + 缺 Review questions 段 |

这 8 条对应 lint 的 8 个 warning（`CLOSED_NOT_ARCHIVED` ×2、`VERDICT_WITHOUT_REVIEW` ×5、`TASK_MISSING_REVIEW_QUESTIONS` ×1）。

> ⚠️ `.tasks/` 已 gitignore，**归档= 物理移到 `.tasks/archive/`，git 里删了不可恢复**。动手前先决定保留策略。

### P2 · 死文件

`PROBE-README.md` — Ximo v1.3.0 时代的沙箱读权限探针，指向已删除的 `D:\15812\mo brain\ximo\`。纯死文件。

### P3 · 空壳目录

`C:\Users\15812\Desktop\.freeze-snap` 和 `D:\15812\.freeze-snap` 均 0 条目。无害，但可考虑清理。

---

## 四、三仓库并行的冲突面

同开三个会话时的真实耦合点，**只有两处**：

### ① 共享 agent-covenant 工具（唯一真冲突面）

`D:\15812\projects\agent-covenant\tools\lint_cards.py` 和 `gate.py` 被本项目引用。

- 本项目**只读调用**，不改 covenant 任何文件。
- 但若另一会话正在改 `tools/*.py`，本项目的门禁结论可能基于半成品代码。
- **动作前核对**：跑门禁前先 `git -C D:\15812\projects\agent-covenant log --oneline -1`，若 HEAD 与上次记录不符，重跑门禁。

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

| 位置 | 事实 |
|---|---|
| `deepfreeze.ps1:12` | manifest 放 `.freeze\manifests` —— 防止 restore 时 `/MIR` 污染源目录造成自我拷贝 |
| `deepfreeze.ps1:60` | 默认 `$AllowedRoot = 'D:\15812'`（**这就是上面那个隐患的根因**） |
| `deepfreeze.ps1:127` | `$SnapRoot = Join-Path $Source '.freeze-snap'` —— 快照目录从被保护源路径推导 |
| `deepfreeze.ps1:207` | robocopy `/XD` 只排除 `<Source>\.freeze` 与 `<Source>\.freeze-snap`（按路径排除，对 junction 生效） |
| `deepfreeze.ps1:249/254/262-264` | 原子提交：先拷 `.tmp`，全成功才 `Move-Item` 成 `snap-<ts>` |
| `deepfreeze.ps1:267-268` | catch 清 `.tmp` + manifest。**「无 `.tmp` 残骸」= 正常异常退出** |
| `verify.ps1:22` | 自检把 `DEEPFREEZE_ALLOWED_ROOT` 钉到仓库自身，所以每次自检都真实走到该配置路径 |

**事故机制辨析**（两次中断机制不同，根因相同）：
- **无 `.tmp` 残骸** → 进程正常抛错退出，catch 跑完了 → 预期行为
- **留下 `.tmp` 残骸** → 进程被硬杀（OOM/手动 kill），catch 没来得及跑

---

## 维护者

主控：OpenCode（jarvis@deepfreeze）
本文件最后核实：2026-10-04