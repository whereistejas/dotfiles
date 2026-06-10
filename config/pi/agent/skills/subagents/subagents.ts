#!/usr/bin/env bun
/**
 * subagents — orchestrate up to 5 parallel pi subagents.
 *
 * Surfaces:
 *   artifact   produces jj commits; gets its own jj workspace.
 *   properties edits non-`@` revisions (jj describe -r, jj split -r,
 *              jj bookmark); shares the parent's cwd. 'merge' is a
 *              no-op (changes are already in the op log).
 *
 * Communication contract (enforced by convention, not the script):
 *   - Parent <-> subagent goes only through jj and this script's
 *     state directory. The state dir is owned by the script;
 *     neither parent nor subagent should touch it directly.
 *   - Subagents do scratch work in /tmp/<NAME>-scratch/, never in
 *     the repo.
 *
 * Runtime dependency: bun (this script's shebang). Plus jj and pi
 * on PATH. No tmux required — subagents are detached background
 * processes; live log view is `subagents tail -f NAME`.
 *
 * State layout (one dir per subagent):
 *   $STATE_ROOT/<NAME>/
 *     meta.json   { name, surface, workspaceDir, forkChangeId,
 *                   model, startedAt, pid }
 *     task        prompt text passed to pi
 *     log         captured stdout/stderr (append-only)
 *     done.json   { exitCode, endedAt }  written on subagent exit
 *
 * forkChangeId is jj's change_id at @ at create time. Stable across
 * rebases, so merge keeps working even if the parent advances.
 */

import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { watch } from "node:fs/promises";
import { basename, dirname, join } from "node:path";

const STATE_ROOT = process.env.PI_SUBAGENTS_STATE_DIR ?? "/tmp/pi-subagents";
const MAX_SUBAGENTS = 5;
const NAME_RE = /^[a-z0-9][a-z0-9-]*$/;
const SCRIPT_PATH = Bun.main;

type Surface = "artifact" | "properties";

type Meta = {
  name: string;
  surface: Surface;
  workspaceDir: string;
  forkChangeId: string;
  model: string;
  startedAt: string;
  pid: number;
};

type Done = {
  exitCode: number;
  endedAt: string;
};

// --- Paths -----------------------------------------------------------

const stateDir = (n: string) => join(STATE_ROOT, n);
const metaPath = (n: string) => join(stateDir(n), "meta.json");
const taskPath = (n: string) => join(stateDir(n), "task");
const logPath = (n: string) => join(stateDir(n), "log");
const donePath = (n: string) => join(stateDir(n), "done.json");
const scratchPath = (n: string) => `/tmp/${n}-scratch`;

// --- I/O helpers -----------------------------------------------------

function readMeta(name: string): Meta {
  return JSON.parse(readFileSync(metaPath(name), "utf8"));
}
function writeMeta(name: string, m: Meta): void {
  writeFileSync(metaPath(name), JSON.stringify(m, null, 2) + "\n");
}
function readDone(name: string): Done | null {
  try {
    return JSON.parse(readFileSync(donePath(name), "utf8"));
  } catch {
    return null;
  }
}
function writeDone(name: string, d: Done): void {
  writeFileSync(donePath(name), JSON.stringify(d, null, 2) + "\n");
}
function listNames(): string[] {
  if (!existsSync(STATE_ROOT)) return [];
  return readdirSync(STATE_ROOT)
    .filter((n) => {
      try {
        return statSync(join(STATE_ROOT, n)).isDirectory();
      } catch {
        return false;
      }
    })
    .sort();
}
function isAlive(pid: number): boolean {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

// --- Error handling --------------------------------------------------

function die(msg: string): never {
  process.stderr.write(`subagents: ${msg}\n\n`);
  printUsage(process.stderr);
  process.exit(1);
}

function requireName(cmd: string, name: string | undefined): asserts name is string {
  if (!name) die(`${cmd}: NAME is required (first arg)`);
  if (!existsSync(stateDir(name))) {
    process.stderr.write(`subagents: ${cmd}: no such subagent: '${name}'. Known:\n`);
    for (const n of listNames()) process.stderr.write(`  ${n}\n`);
    process.stderr.write("\n");
    printUsage(process.stderr);
    process.exit(1);
  }
}

// --- Shell helpers ---------------------------------------------------

type ShOptions = { cwd?: string; allowFailure?: boolean };

async function sh(cmd: string[], opts: ShOptions = {}): Promise<string> {
  const proc = Bun.spawn(cmd, {
    cwd: opts.cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const exit = await proc.exited;
  if (exit !== 0 && !opts.allowFailure) {
    die(`${cmd[0]} failed (exit ${exit}): ${stderr.trim() || stdout.trim() || "no output"}`);
  }
  return stdout;
}

const jj = (...args: string[]) => sh(["jj", ...args]);
const jjMaybe = (...args: string[]) => sh(["jj", ...args], { allowFailure: true });

// --- Effective status (handles crashed subagents) --------------------

type Status =
  | { state: "running"; exitCode: null }
  | { state: "done"; exitCode: number }
  | { state: "crashed"; exitCode: number };

function effectiveStatus(name: string): Status {
  const d = readDone(name);
  if (d) return { state: "done", exitCode: d.exitCode };
  let meta: Meta;
  try {
    meta = readMeta(name);
  } catch {
    // No meta and no done — synthesise crashed.
    const synth: Done = { exitCode: -1, endedAt: new Date().toISOString() };
    writeDone(name, synth);
    return { state: "crashed", exitCode: -1 };
  }
  if (isAlive(meta.pid)) return { state: "running", exitCode: null };
  // Process gone but no done.json — memoise as crashed.
  const synth: Done = { exitCode: -1, endedAt: new Date().toISOString() };
  writeDone(name, synth);
  return { state: "crashed", exitCode: -1 };
}

// --- create ----------------------------------------------------------

async function cmdCreate(argv: string[]): Promise<void> {
  let surface: Surface = "artifact";
  let model = "";
  let base = "";
  let i = 0;
  while (i < argv.length) {
    const a = argv[i];
    if (a === "--surface") {
      const v = argv[i + 1];
      if (!v) die("create: --surface needs a value (artifact|properties)");
      if (v !== "artifact" && v !== "properties") {
        die(`create: --surface must be 'artifact' or 'properties' (got '${v}')`);
      }
      surface = v;
      i += 2;
    } else if (a === "--model") {
      const v = argv[i + 1];
      if (!v) die("create: --model needs a value");
      model = v;
      i += 2;
    } else if (a === "--base") {
      const v = argv[i + 1];
      if (!v) die("create: --base needs a revset (e.g. a change_id or bookmark)");
      base = v;
      i += 2;
    } else if (a === "--") {
      i += 1;
      break;
    } else if (a.startsWith("-")) {
      die(`create: unknown flag '${a}'`);
    } else {
      break;
    }
  }
  const name = argv[i];
  const taskFile = argv[i + 1];
  if (!name) die("create: NAME is required");
  if (!taskFile) die("create: TASK_FILE is required");
  if (!NAME_RE.test(name)) {
    die(`create: NAME '${name}' is invalid — must match [a-z0-9][a-z0-9-]* (e.g. 'port-redaction', 'tests-1')`);
  }
  if (!existsSync(taskFile)) {
    die(`create: TASK_FILE '${taskFile}' does not exist — write the prompt to a file first`);
  }
  if (existsSync(stateDir(name))) {
    die(`create: subagent '${name}' already exists — 'subagents delete ${name}' first`);
  }

  mkdirSync(STATE_ROOT, { recursive: true });
  if (listNames().length >= MAX_SUBAGENTS) {
    process.stderr.write(`subagents: create: max (${MAX_SUBAGENTS}) subagents reached. Currently:\n`);
    await cmdList();
    process.stderr.write("\nMerge or delete one before spawning another.\n");
    process.exit(1);
  }

  const repoRoot = (await sh(["jj", "workspace", "root"], { allowFailure: true })).trim();
  if (!repoRoot) die("create: not inside a jj workspace — cd to a repo first");

  if (base && surface === "properties") {
    die("create: --base is only valid for --surface artifact (properties subagents share the parent cwd)");
  }
  const forkRevset = base || "@";
  const fork = (await jj("log", "-r", forkRevset, "--no-graph", "-T", "change_id", "--ignore-working-copy")).trim();
  if (!fork) die(`create: could not resolve '${forkRevset}' to a change_id`);
  if (fork.includes("\n")) die(`create: '${forkRevset}' resolved to multiple revisions — narrow it down`);

  let workspaceDir: string;
  if (surface === "artifact") {
    workspaceDir = join(dirname(repoRoot), `${basename(repoRoot)}-${name}`);
    if (existsSync(workspaceDir)) {
      die(`create: workspace dir '${workspaceDir}' already exists on disk — remove it first ('rm -rf ${workspaceDir}')`);
    }
    const addArgs = ["workspace", "add", "--name", name];
    if (base) addArgs.push("--revision", fork);
    addArgs.push(workspaceDir);
    await jj(...addArgs);
  } else {
    workspaceDir = repoRoot;
  }

  mkdirSync(stateDir(name), { recursive: true });
  writeFileSync(taskPath(name), readFileSync(taskFile));

  // Write meta with placeholder pid so the runner can read other fields
  // immediately. Update pid after spawn.
  const meta: Meta = {
    name,
    surface,
    workspaceDir,
    forkChangeId: fork,
    model,
    startedAt: new Date().toISOString(),
    pid: 0,
  };
  writeMeta(name, meta);

  const runner = Bun.spawn(["bun", SCRIPT_PATH, "__run", name], {
    cwd: workspaceDir,
    stdio: ["ignore", "ignore", "ignore"],
    env: process.env,
  });
  runner.unref();

  meta.pid = runner.pid;
  writeMeta(name, meta);

  process.stdout.write(`spawned ${name}\n`);
  process.stdout.write(`  surface:   ${surface}\n`);
  process.stdout.write(`  workspace: ${workspaceDir}\n`);
  process.stdout.write(`  fork:      ${fork}\n`);
  if (model) process.stdout.write(`  model:     ${model}\n`);
  process.stdout.write(`  pid:       ${runner.pid}\n`);
  process.stdout.write(`  log:       ${logPath(name)}\n`);
}

// --- __run (internal: invoked by `create` as the detached child) ----

async function cmdRun(argv: string[]): Promise<void> {
  const name = argv[0];
  if (!name) {
    process.stderr.write("__run: NAME required\n");
    process.exit(2);
  }
  const meta = readMeta(name);
  const task = readFileSync(taskPath(name), "utf8");

  const piArgs = ["-p", "--no-skills"];
  if (meta.model) piArgs.push("--model", meta.model);
  piArgs.push(task);

  // pi's shebang is `#!/usr/bin/env node`. Some hosts have a Node
  // version that crashes the bundled `undici` (e.g. Node 20.11 +
  // newer undici: `webidl.util.markAsUncloneable is not a function`).
  // Run pi under bun's runtime instead — mirrors the user's
  // `alias pi='bun run $(which pi)'`.
  const piPath = Bun.which("pi");
  if (!piPath) {
    process.stderr.write("__run: pi not found on PATH\n");
    process.exit(2);
  }

  const logFd = openSync(logPath(name), "a");
  const child = Bun.spawn(["bun", "run", piPath, ...piArgs], {
    cwd: meta.workspaceDir,
    stdio: ["ignore", logFd, logFd],
    env: process.env,
  });

  // Forward common termination signals to the child.
  const forward = (sig: NodeJS.Signals) => () => {
    try {
      child.kill(sig);
    } catch {}
  };
  process.on("SIGTERM", forward("SIGTERM"));
  process.on("SIGINT", forward("SIGINT"));
  process.on("SIGHUP", forward("SIGHUP"));

  const exitCode = await child.exited;
  closeSync(logFd);
  writeDone(name, { exitCode, endedAt: new Date().toISOString() });
  process.exit(exitCode);
}

// --- list ------------------------------------------------------------

async function cmdList(): Promise<void> {
  const names = listNames();
  if (names.length === 0) {
    process.stdout.write("no subagents\n");
    return;
  }
  const rows: string[][] = [["NAME", "SURFACE", "STATUS", "EXIT", "WORKSPACE"]];
  for (const name of names) {
    let meta: Meta | null = null;
    try {
      meta = readMeta(name);
    } catch {}
    if (!meta) {
      rows.push([name, "?", "corrupt", "-", "-"]);
      continue;
    }
    const st = effectiveStatus(name);
    const exit = st.exitCode === null ? "-" : String(st.exitCode);
    rows.push([name, meta.surface, st.state, exit, meta.workspaceDir]);
  }
  const widths = rows[0].map((_, c) => Math.max(...rows.map((r) => r[c].length)));
  for (const r of rows) {
    process.stdout.write(r.map((v, c) => v.padEnd(widths[c])).join("  ") + "\n");
  }
}

// --- tail ------------------------------------------------------------

async function cmdTail(argv: string[]): Promise<void> {
  let n = 20;
  let follow = false;
  let i = 0;
  while (i < argv.length) {
    const a = argv[i];
    if (a === "-n") {
      const v = argv[i + 1];
      if (!v) die("tail: -n needs a number");
      const parsed = parseInt(v, 10);
      if (isNaN(parsed) || parsed < 0) die(`tail: -n must be a non-negative integer (got '${v}')`);
      n = parsed;
      i += 2;
    } else if (a === "-f") {
      follow = true;
      i += 1;
    } else if (a.startsWith("-")) {
      die(`tail: unknown flag '${a}'`);
    } else {
      break;
    }
  }
  const name = argv[i];
  requireName("tail", name);
  const log = logPath(name);
  if (!existsSync(log)) die(`tail: no log for '${name}' yet`);

  const content = readFileSync(log, "utf8");
  const lines = content.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  const start = Math.max(0, lines.length - n);
  for (let j = start; j < lines.length; j++) process.stdout.write(lines[j] + "\n");

  if (!follow) return;

  let pos = statSync(log).size;
  // Stop following once the subagent has finished writing.
  let stopped = false;
  const watcher = watch(log);
  const poll = setInterval(() => {
    if (readDone(name)) {
      stopped = true;
      // Drain anything written between last event and now.
      drain();
      process.exit(0);
    }
  }, 500);

  function drain() {
    const size = statSync(log).size;
    if (size > pos) {
      const fd = openSync(log, "r");
      const buf = Buffer.alloc(size - pos);
      readSync(fd, buf, 0, size - pos, pos);
      closeSync(fd);
      process.stdout.write(buf);
      pos = size;
    } else if (size < pos) {
      pos = 0;
    }
  }

  try {
    for await (const _ of watcher) {
      if (stopped) break;
      drain();
    }
  } finally {
    clearInterval(poll);
  }
}

// --- log -------------------------------------------------------------

async function cmdLog(argv: string[]): Promise<void> {
  const name = argv[0];
  requireName("log", name);
  const log = logPath(name);
  if (!existsSync(log)) die(`log: no log for '${name}' yet`);
  process.stdout.write(readFileSync(log));
}

// --- merge -----------------------------------------------------------

async function cmdMerge(argv: string[]): Promise<void> {
  const name = argv[0];
  requireName("merge", name);
  const st = effectiveStatus(name);
  if (st.state === "running") {
    die(`merge: '${name}' is still running — wait for it ('subagents list' to check)`);
  }
  if (st.exitCode !== 0) {
    process.stderr.write(`subagents: merge: '${name}' exited ${st.exitCode} — refusing to merge.\n`);
    process.stderr.write(`Inspect the log: subagents log ${name}\n`);
    process.stderr.write(`Then drop the work:  subagents delete ${name}\n`);
    process.exit(1);
  }

  const meta = readMeta(name);
  if (meta.surface === "properties") {
    process.stdout.write(`${name} (properties): nothing to merge — changes are in the jj op log.\n`);
    process.stdout.write("Inspect with: jj op log -n 20\n");
    return;
  }

  const fork = meta.forkChangeId;
  const revset = `${fork}..${name}@`;

  await jjMaybe("abandon", "-r", `empty() & (${revset})`);

  const tmpl = 'change_id ++ "\\n"';
  const roots = (await jjMaybe("log", "-r", `roots(${revset})`, "--no-graph", "-T", tmpl))
    .trim()
    .split("\n")
    .filter(Boolean);
  const heads = (await jjMaybe("log", "-r", `heads(${revset})`, "--no-graph", "-T", tmpl))
    .trim()
    .split("\n")
    .filter(Boolean);

  if (roots.length === 0) {
    process.stdout.write(`${name} produced no non-empty commits — nothing to merge\n`);
    return;
  }
  if (roots.length > 1) {
    die(
      `merge: '${name}' has ${roots.length} roots in '${revset}', expected 1. ` +
        `Run 'jj log -r '${revset}'' to inspect; this orchestration may need manual cleanup.`,
    );
  }
  if (heads.length > 1) {
    die(
      `merge: '${name}' has ${heads.length} heads in '${revset}', expected 1. ` +
        `Run 'jj log -r '${revset}'' to inspect; this orchestration may need manual cleanup.`,
    );
  }

  // Capture parent's @ before the rebase so we can advance it afterwards
  // and clean it up if it was empty.
  const oldAt = (await jj("log", "-r", "@", "--no-graph", "-T", "change_id")).trim();
  const tip = heads[0];

  await jj("rebase", "--source", roots[0], "--destination", "@");

  // Position parent's working copy on top of the merged tip so the
  // subagent's work is visible in the parent's normal history view.
  await jj("new", tip);

  process.stdout.write(`${name} merged. New commits on parent:\n`);
  const summary = await jj(
    "log",
    "-r",
    `${oldAt}..${tip}`,
    "--no-graph",
    "-T",
    'change_id.short() ++ " " ++ description.first_line() ++ "\\n"',
  );
  process.stdout.write(summary);

  // If parent's old @ was an empty working-copy commit, drop it so the
  // history stays linear.
  await jjMaybe("abandon", "-r", `empty() & ${oldAt}`);
}

// --- delete ----------------------------------------------------------

async function cmdDelete(argv: string[]): Promise<void> {
  const name = argv[0];
  requireName("delete", name);

  let meta: Meta | null = null;
  try {
    meta = readMeta(name);
  } catch {}

  const st = effectiveStatus(name);
  if (st.state === "running" && meta) {
    try {
      process.kill(meta.pid, "SIGTERM");
    } catch {}
    // Wait up to 2s for graceful exit.
    for (let i = 0; i < 20 && isAlive(meta.pid); i++) await Bun.sleep(100);
    if (isAlive(meta.pid)) {
      try {
        process.kill(meta.pid, "SIGKILL");
      } catch {}
    }
    if (!readDone(name)) {
      writeDone(name, { exitCode: 130, endedAt: new Date().toISOString() });
    }
  }

  if (meta?.surface === "artifact") {
    await jjMaybe("workspace", "forget", name);
    const repoRoot = (await sh(["jj", "workspace", "root"], { allowFailure: true })).trim();
    if (
      meta.workspaceDir &&
      existsSync(meta.workspaceDir) &&
      meta.workspaceDir !== repoRoot
    ) {
      rmSync(meta.workspaceDir, { recursive: true, force: true });
    }
  }

  if (existsSync(scratchPath(name))) {
    rmSync(scratchPath(name), { recursive: true, force: true });
  }
  if (existsSync(stateDir(name))) {
    rmSync(stateDir(name), { recursive: true, force: true });
  }
  process.stdout.write(`${name} deleted\n`);
}

// --- usage -----------------------------------------------------------

function printUsage(stream: NodeJS.WriteStream = process.stdout): void {
  stream.write(`subagents — run up to ${MAX_SUBAGENTS} pi subagents in parallel.

Commands:
  subagents create [--surface SURFACE] [--model MODEL] [--base REVSET]
                   NAME TASK_FILE
                                    spawn a subagent
  subagents list                    show all subagents with status
  subagents tail [-n N] [-f] NAME   last N (default 20) lines of log;
                                    -f to follow live until subagent ends
  subagents log NAME                full log
  subagents merge NAME              merge a finished subagent
  subagents delete NAME             stop subagent, clean up state
  subagents --help                  show this message

Surfaces:
  artifact   (default) produces jj commits; gets its own jj workspace.
                       'merge' rebases the commits onto the parent's @.
  properties           edits non-@ revisions only (jj describe -r,
                       jj split -r, jj bookmark). Shares the parent's
                       cwd. 'merge' is a no-op.

Models (--model PATTERN, use provider/id form):
  mechanical: --model anthropic/claude-haiku-4-5
  local:      --model anthropic/claude-sonnet-4-5
  reasoning:  omit --model (inherit parent's default)

Base commit (--base REVSET, artifact only):
  Fork the subagent's workspace from REVSET instead of @. Useful when
  the parent's @ has uncommitted work that the subagent shouldn't
  inherit, or when two subagents should fork from different points.
  REVSET must resolve to exactly one revision.

Constraints:
  - max ${MAX_SUBAGENTS} subagents at a time (merge or delete to free a slot)
  - NAME must match [a-z0-9][a-z0-9-]* (lowercase, digits, hyphens)
  - TASK_FILE is a plain text file with the prompt for one subagent
  - run from inside a jj workspace
  - subagents use /tmp/<NAME>-scratch/ for their own scratch work

State directory:
  ${STATE_ROOT}  (set PI_SUBAGENTS_STATE_DIR to override)
  Owned by this script. Do not read or write it directly.

Notes:
  - merge refuses to run if exit code != 0 — read the log, then delete.
  - delete sends SIGTERM (then SIGKILL after 2s) to a still-running
    subagent, cleans up the jj workspace (artifact only), scratch
    folder, and state.
  - Subagents run with 'pi -p --no-skills'; no recursion into this
    skill. They inherit the parent's default session storage in
    ~/.pi/agent/sessions/.
  - Runtime deps: bun, jj, pi.
`);
}

// --- main ------------------------------------------------------------

async function main(): Promise<void> {
  const [cmd, ...rest] = process.argv.slice(2);
  switch (cmd) {
    case "create":
      await cmdCreate(rest);
      break;
    case "list":
      await cmdList();
      break;
    case "tail":
      await cmdTail(rest);
      break;
    case "log":
      await cmdLog(rest);
      break;
    case "merge":
      await cmdMerge(rest);
      break;
    case "delete":
      await cmdDelete(rest);
      break;
    case "__run":
      await cmdRun(rest);
      break;
    case "-h":
    case "--help":
      printUsage();
      break;
    case undefined:
      printUsage(process.stderr);
      process.exit(2);
      break;
    default:
      process.stderr.write(`subagents: unknown command: '${cmd}'\n\n`);
      printUsage(process.stderr);
      process.exit(2);
  }
}

await main();
