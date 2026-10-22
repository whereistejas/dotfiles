import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

export interface Workspace {
	dir: string;
	/** What the worker must be told about it, e.g. that a warm-up build is running there. */
	brief?: string;
}

/** A sibling jj workspace at `cwd`'s working-copy commit, made by `agent-workspace` from the dotfiles' scripts. */
export async function addWorkspace(cwd: string, name: string): Promise<Workspace> {
	const { stdout } = await run("agent-workspace", ["add", name], { cwd });
	const fields = new Map(stdout.split("\n").filter(Boolean).map((line) => {
		const at = line.indexOf("=");
		return [line.slice(0, at), line.slice(at + 1)];
	}));
	const dir = fields.get("dir");
	if (!dir) throw new Error(`agent-workspace printed no dir: ${stdout}`);
	return { dir, brief: fields.get("brief") };
}

/** Stops its warm-up build, forgets it (its edits stay in its commit) and deletes its folder. */
export async function removeWorkspace(dir: string): Promise<void> {
	await run("agent-workspace", ["remove", dir]);
}
