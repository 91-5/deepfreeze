// tools/autosnap-selftest.mjs — 验收测试 for the deepfreeze-autosnap plugin.
//
// Run: bun tools/autosnap-selftest.mjs   (from the deepfreeze repo root)
// Uses a real PowerShell subprocess per scenario (the plugin's actual code
// path: execFile → powershell -File <DEEPFREEZE_SCRIPT>), so what this
// proves is what production does — no mocked internals.
//
// Scenarios (DFB-20261021-002 D2): 触发 / 节流 / 窗口过期 / 非写工具 /
// 白名单外 / fail-open / 失败后重试 / 状态原子性。

import { strict as assert } from "node:assert"
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { homedir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

const pluginPath = process.env.DEEPFREEZE_AUTOSNAP_PLUGIN
  || join(homedir(), ".config", "opencode", "plugins", "deepfreeze-autosnap.js")
const { DeepfreezeAutosnap } = await import(pathToFileURL(pluginPath).href)

let pass = 0, fail = 0
async function check(name, fn) {
  try { await fn(); pass++; console.log(`  [PASS] ${name}`) }
  catch (e) { fail++; console.log(`  [FAIL] ${name} -- ${e?.message ?? e}`) }
}

function makeTempRoot() { return mkdtempSync(join(tmpdir(), "autosnap-test-")) }

// A real .ps1 "protect" double: appends to a log file, exits 0.
function writeDummyPs1(dir, logPath) {
  const p = join(dir, "dummy.ps1")
  writeFileSync(p, `Add-Content -LiteralPath "${logPath.replace(/\\/g, "\\\\")}" -Value "snap"\n`)
  return p
}
// A .ps1 that exits 1 (protect "fails").
function writeFailingPs1(dir) {
  const p = join(dir, "failing.ps1")
  writeFileSync(p, "exit 1\n")
  return p
}

function makePlugin(overrides = {}) {
  process.env.DEEPFREEZE_SCRIPT = overrides.script ?? ""
  if (overrides.roots !== undefined) process.env.DEEPFREEZE_AUTOSNAP_ROOTS = overrides.roots
  else delete process.env.DEEPFREEZE_AUTOSNAP_ROOTS
  if (overrides.tools !== undefined) process.env.DEEPFREEZE_AUTOSNAP_TOOLS = overrides.tools
  else delete process.env.DEEPFREEZE_AUTOSNAP_TOOLS
  delete process.env.DEEPFREEZE_AUTOSNAP_WINDOW_SEC
  return DeepfreezeAutosnap({ worktree: overrides.worktree ?? null, directory: overrides.directory ?? null })
}

const hook = (hooks) => hooks["tool.execute.before"]
const callHook = async (hooks, tool, filePath) =>
  hook(hooks)({ tool }, { args: { filePath } })

const stateFile = (root) => join(root, ".freeze", "autosnap-state.json")

const tmp = makeTempRoot()
let logSeq = 0
// Per-scenario log: a shared log would let earlier scenarios' protects
// pollute later "not invoked" assertions (the exact bug the first run caught).
function scenarioLog() {
  logSeq++
  return join(tmp, `protect-log-${logSeq}.txt`)
}

await check("1 触发: write 工具命中 → protect 被调用 + 状态文件产生", async () => {
  const root = makeTempRoot()
  const dummyLog = scenarioLog()
  writeFileSync(join(root, ".deepfreeze-autosnap"), "")
  const script = writeDummyPs1(tmp, dummyLog)
  const hooks = await makePlugin({ script })
  await callHook(hooks, "edit", join(root, "src", "a.txt"))
  assert.ok(existsSync(dummyLog), "dummy protect 未被调用")
  assert.ok(existsSync(stateFile(root)), "节流状态文件未产生")
})

await check("2 节流: 窗口内第二次写不触发", async () => {
  const root = makeTempRoot()
  const dummyLog = scenarioLog()
  writeFileSync(join(root, ".deepfreeze-autosnap"), "")
  const script = writeDummyPs1(tmp, dummyLog)
  const hooks = await makePlugin({ script })
  await callHook(hooks, "edit", join(root, "a.txt"))
  const count1 = readFileSync(dummyLog, "utf-8").trim().split("\n").length
  await callHook(hooks, "write", join(root, "b.txt"))
  const count2 = readFileSync(dummyLog, "utf-8").trim().split("\n").length
  assert.equal(count2, count1, `节流失效: ${count1} → ${count2}`)
})

await check("3 窗口过期: lastSnapAt 拨回 20 分钟前 → 再次触发", async () => {
  const root = makeTempRoot()
  const dummyLog = scenarioLog()
  writeFileSync(join(root, ".deepfreeze-autosnap"), "")
  const script = writeDummyPs1(tmp, dummyLog)
  const hooks = await makePlugin({ script })
  await callHook(hooks, "edit", join(root, "a.txt"))
  const count1 = readFileSync(dummyLog, "utf-8").trim().split("\n").length
  const state = JSON.parse(readFileSync(stateFile(root), "utf-8"))
  state.lastSnapAt = new Date(Date.now() - 20 * 60 * 1000).toISOString()
  writeFileSync(stateFile(root), JSON.stringify(state))
  await callHook(hooks, "edit", join(root, "b.txt"))
  const count2 = readFileSync(dummyLog, "utf-8").trim().split("\n").length
  assert.equal(count2, count1 + 1, `窗口过期后未触发: ${count1} → ${count2}`)
})

await check("4 非写工具: read/bash 不触发", async () => {
  const root = makeTempRoot()
  const dummyLog = scenarioLog()
  writeFileSync(join(root, ".deepfreeze-autosnap"), "")
  const script = writeDummyPs1(tmp, dummyLog)
  const hooks = await makePlugin({ script })
  await callHook(hooks, "read", join(root, "a.txt"))
  await callHook(hooks, "bash", join(root, "a.txt"))
  assert.ok(!existsSync(dummyLog), "非写工具触发了 protect")
})

await check("5 白名单外目录不触发（无标记、roots 指向他处、worktree=null）", async () => {
  const root = makeTempRoot()
  const dummyLog = scenarioLog()
  const other = makeTempRoot()
  const script = writeDummyPs1(tmp, dummyLog)
  const hooks = await makePlugin({ script, roots: other })
  await callHook(hooks, "edit", join(root, "a.txt"))
  assert.ok(!existsSync(dummyLog), "白名单外目录触发了 protect")
})

await check("6 fail-open: protect 失败（exit 1）→ hook 不抛错、写操作照常", async () => {
  const root = makeTempRoot()
  const dummyLog = scenarioLog()
  writeFileSync(join(root, ".deepfreeze-autosnap"), "")
  const script = writeFailingPs1(tmp)
  const hooks = await makePlugin({ script })
  // 不抛错 = 通过（hook 内部 catch 掉 protect 失败）
  await callHook(hooks, "edit", join(root, "a.txt"))
})

await check("7 失败后重试: protect 失败重置窗口 → 下一次写立即重试", async () => {
  const root = makeTempRoot()
  const dummyLog = scenarioLog()
  writeFileSync(join(root, ".deepfreeze-autosnap"), "")
  const failing = writeFailingPs1(tmp)
  const hooksFail = await makePlugin({ script: failing })
  await callHook(hooksFail, "edit", join(root, "a.txt"))
  const state = JSON.parse(readFileSync(stateFile(root), "utf-8"))
  assert.ok(!state.lastSnapAt, "失败后窗口槽未被重置")
  const script = writeDummyPs1(tmp, dummyLog)
  const hooksOk = await makePlugin({ script })
  await callHook(hooksOk, "edit", join(root, "b.txt"))
  assert.ok(existsSync(dummyLog), "失败重置后下一次写未重试 protect")
})

await check("8 状态原子性: hook 调用后 .freeze 下无 .tmp 残留，状态可解析", async () => {
  const root = makeTempRoot()
  const dummyLog = scenarioLog()
  writeFileSync(join(root, ".deepfreeze-autosnap"), "")
  const script = writeDummyPs1(tmp, dummyLog)
  const hooks = await makePlugin({ script })
  await callHook(hooks, "edit", join(root, "a.txt"))
  const residue = readdirSync(join(root, ".freeze")).filter(f => f.includes(".tmp"))
  assert.equal(residue.length, 0, `残留 tmp: ${residue.join(",")}`)
  assert.ok(JSON.parse(readFileSync(stateFile(root), "utf-8")).lastSnapAt)
})

// 9 契约测试（DFB-20261021-002 B1 blocker）：文档写 DEEPFREEZE_SCRIPT（2 个 E），
// 插件曾写 DEEEPFREEZE_SCRIPT（3 个 E）——「测试与 bug 自洽」的 8/8 假绿盖住了
// 契约断裂（sir 按文档名设 env，插件读不到 → 核心能力从未触发）。
// 本测试逐字对照 README 配置表 + 硬断言「按文档名设 env → protect 触发」。
await check("9 契约: 按文档名 DEEPFREEZE_SCRIPT 设 env → protect 必须触发（防 typo 再脱节）", async () => {
  // 硬断言 1：本测试用的 env key 必须与 README 配置表逐字一致
  // （README 里还有 deepfreeze 原有的 DEEPFREEZE_ALLOWED_ROOT，所以必须收窄到
  //  宿主集成配置表中「deepfreeze.ps1 绝对路径」那一行，不能取第一个匹配）
  const readme = readFileSync("README.md", "utf-8")
  // 安全设计表的「规模护栏」行也提到 deepfreeze.ps1（line 160）——必须同时要求
  // 大写 DEEPFREEZE 才能锁定宿主集成配置表的 DEEPFREEZE_SCRIPT 行
  const tableRow = readme.split("\n").find(l => l.includes("|") && l.includes("DEEPFREEZE") && l.includes("deepfreeze.ps1"))
  assert.ok(tableRow, "README 宿主集成配置表里找不到 DEEPFREEZE_SCRIPT 行 —— 测试与文档已脱节")
  const docName = tableRow.match(/`([A-Z_]+)`/)?.[1]
  assert.equal(docName, "DEEPFREEZE_SCRIPT", `文档 env 名漂移: ${docName}`)
  // 硬断言 2：插件源码读取的每个 env 名都必须在 README 配置表里记载
  const src = readFileSync(pluginPath, "utf-8")
  const readSites = [...src.matchAll(/process\.env\.([A-Z_]+)/g)].map(m => m[1])
  for (const name of readSites) {
    assert.ok(readme.includes(`\`${name}\``),
      `插件读取了文档没记载的 env: ${name} —— 契约断裂（B1 同族）`)
  }
  // 行为断言：按文档名设 env（清掉可能的旧错名残留）→ 必须触发
  const root = makeTempRoot()
  writeFileSync(join(root, ".deepfreeze-autosnap"), "")
  const dummyLog = scenarioLog()
  const script = writeDummyPs1(tmp, dummyLog)
  const hooks = await makePlugin({ script })
  await callHook(hooks, "edit", join(root, "a.txt"))
  assert.ok(existsSync(dummyLog),
    "按文档名 DEEPFREEZE_SCRIPT 设 env 但 protect 未触发 —— 契约断裂复发")
})

// cleanup
rmSync(tmp, { recursive: true, force: true })

console.log(`\n结果: ${pass} pass / ${fail} fail`)
process.exit(fail > 0 ? 1 : 0)
