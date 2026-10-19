/**
 * nvim-terminal extension.
 *
 * When pi runs in a Neovim terminal ($NVIM is set), it registers itself with
 * that terminal buffer so servery.nvim can list and restore pi sessions:
 *
 * - renames the buffer to `term://<cwd>//<pid>:pi --session <file>`, so
 *   `:mksession` restores the terminal by resuming this session
 * - sets `b:pi_session = { id, file, cwd, name?, status, pid }`, with status
 *   "running" during a turn and "idle" otherwise
 *
 * Outside the TUI (e.g. `pi -p` subagents, which would find their parent's
 * terminal), without $NVIM, or when the buffer can't be found, it does nothing.
 */

import { execFile, execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const LUA = path.join(path.dirname(fileURLToPath(import.meta.url)), "nvim.lua");
const run = promisify(execFile);

type Status = "idle" | "running";

interface PiSession {
	id: string;
	file?: string;
	cwd: string;
	name?: string;
	status: Status;
	pid: number;
}

/** pi and its ancestors; one of them is the job of the nvim terminal pi runs in. */
function lineage(): number[] {
	const pids: number[] = [];
	for (let pid = process.pid; pid > 1 && pids.length < 16; ) {
		pids.push(pid);
		pid = Number(execFileSync("ps", ["-o", "ppid=", "-p", String(pid)]).toString().trim());
	}
	return pids;
}

const vimString = (s: string) => `'${s.replace(/'/g, "''")}'`;

export default function (pi: ExtensionAPI) {
	let enabled = false;
	let pids: number[] | undefined;
	let buf: number | undefined;
	let queue: Promise<void> = Promise.resolve();

	async function call(fn: string, args: object): Promise<void> {
		const server = process.env.NVIM;
		if (!enabled || !server) return;

		pids ??= lineage();
		const json = JSON.stringify({ ...args, pids, buf });
		const expr = `luaeval('vim.json.encode(dofile(_A[1])[_A[2]](vim.json.decode(_A[3])))', [${[LUA, fn, json].map(vimString).join(", ")}])`;
		const { stdout } = await run("nvim", ["--clean", "--headless", "--server", server, "--remote-expr", expr], {
			timeout: 5000,
		});
		const result = JSON.parse(stdout) as { buf?: number };
		buf = result.buf;
	}

	/** Runs calls in order and swallows every failure: this is bookkeeping, never worth an error. */
	function enqueue(fn: string, args: () => object): Promise<void> {
		queue = queue.then(() => call(fn, args())).catch(() => {});
		return queue;
	}

	function session(ctx: ExtensionContext, status: Status): PiSession {
		return {
			id: ctx.sessionManager.getSessionId(),
			file: ctx.sessionManager.getSessionFile(),
			cwd: ctx.cwd,
			name: pi.getSessionName(),
			status,
			pid: process.pid,
		};
	}

	pi.on("session_start", (_event, ctx) => {
		enabled = ctx.mode === "tui";
		void enqueue("register", () => {
			const info = session(ctx, ctx.isIdle() ? "idle" : "running");
			return { file: info.file, session: info };
		});
	});

	pi.on("agent_start", () => {
		void enqueue("update", () => ({ status: "running", name: pi.getSessionName() }));
	});

	pi.on("agent_end", () => {
		void enqueue("update", () => ({ status: "idle", name: pi.getSessionName() }));
	});

	pi.on("session_info_changed", (event, ctx) => {
		void enqueue("update", () => ({ status: ctx.isIdle() ? "idle" : "running", name: event.name }));
	});

	pi.on("session_shutdown", async () => {
		await enqueue("clear", () => ({}));
	});
}
