import { execFile, execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const LUA = path.join(path.dirname(fileURLToPath(import.meta.url)), "nvim.lua");
const run = promisify(execFile);

export function requireNvim(): void {
	if (!process.env.NVIM) throw new Error("branch needs Neovim ($NVIM is unset)");
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

async function call<T>(fn: string, args: object): Promise<T> {
	requireNvim();
	const json = JSON.stringify({ ...args, pids: lineage() });
	const expr = `luaeval('vim.json.encode(dofile(_A[1])[_A[2]](vim.json.decode(_A[3])))', [${[LUA, fn, json].map(vimString).join(", ")}])`;
	const { stdout } = await run("nvim", ["--clean", "--headless", "--server", process.env.NVIM!, "--remote-expr", expr], {
		timeout: 5000,
	});
	const result = JSON.parse(stdout) as T & { error?: string };
	if (result.error) throw new Error(result.error);
	return result;
}

export interface OpenOptions {
	name: string;
	cmd: string[];
	cwd: string;
	/** Where nvim records the exit code and last screen lines when `cmd` exits. */
	exitFile?: string;
	/** Show the new terminal in pi's window, hiding pi's own terminal. */
	show: boolean;
}

/** Starts `cmd` in a new terminal buffer. Returns it and the buffer pi itself runs in. */
export const openTerminal = (opts: OpenOptions) =>
	call<{ buf: number; own?: number }>("open", { name: opts.name, cmd: opts.cmd, cwd: opts.cwd, exit_file: opts.exitFile, show: opts.show });

export const showBuffer = (buf: number) => call<object>("show", { buf });
