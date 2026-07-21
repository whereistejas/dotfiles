/**
 * Minimal footer: replaces the built-in footer with a single line
 *   <repo-name> • <work-item> • <jj change | git commit> • <session>  …  ↑in ↓out
 * Work item is fetched from Obsidian daily note property "current_work_item".
 * Shows "no work item" when not set.
 * Hides model id, thinking level, cost, and context %.
 *
 * Rev info is refreshed event-driven by watching jj/git state files so
 * external commits (other terminals) and `!` user-bash commits show up
 * immediately. `turn_end` is kept as a cheap backstop.
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { watch, type FSWatcher } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { basename, dirname, join, isAbsolute } from "node:path";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

const exec = promisify(execFile);

type RepoInfo = {
	jjOpHeadsDir?: string;
	gitDir?: string;
	repoRoot?: string;
};

async function pathExists(p: string): Promise<boolean> {
	try {
		await stat(p);
		return true;
	} catch {
		return false;
	}
}

async function resolveGitDir(dotGit: string): Promise<string | undefined> {
	try {
		const s = await stat(dotGit);
		if (s.isDirectory()) return dotGit;
		// .git is a file — "gitdir: <path>" (worktrees, submodules)
		const text = await readFile(dotGit, "utf8");
		const m = text.match(/^gitdir:\s*(.+?)\s*$/m);
		if (m) {
			const target = m[1];
			return isAbsolute(target) ? target : join(dirname(dotGit), target);
		}
	} catch {}
	return undefined;
}

async function findRepoInfo(cwd: string): Promise<RepoInfo> {
	const info: RepoInfo = {};
	let dir = cwd;
	while (true) {
		const jj = join(dir, ".jj");
		if (!info.jjOpHeadsDir && (await pathExists(jj))) {
			const heads = join(jj, "repo", "op_heads", "heads");
			if (await pathExists(heads)) info.jjOpHeadsDir = heads;
		}
		const dotGit = join(dir, ".git");
		if (!info.gitDir && (await pathExists(dotGit))) {
			info.gitDir = await resolveGitDir(dotGit);
		}
		if (info.jjOpHeadsDir || info.gitDir) {
			info.repoRoot = dir;
			return info;
		}
		const parent = dirname(dir);
		if (parent === dir) return info;
		dir = parent;
	}
}

async function getRevInfo(cwd: string): Promise<string | undefined> {
	try {
		const { stdout } = await exec(
			"jj",
			[
				"log",
				"-r",
				"@",
				"--no-graph",
				"--ignore-working-copy",
				"-T",
				'change_id.shortest(8) ++ " " ++ if(description, description.first_line(), "(no description)")',
			],
			{ cwd, timeout: 1500 },
		);
		const line = stdout.trim();
		if (line) return line;
	} catch {}

	try {
		const { stdout } = await exec("git", ["log", "-1", "--format=%h %s"], { cwd, timeout: 1500 });
		const line = stdout.trim();
		if (line) return line;
	} catch {}

	return undefined;
}

async function getCurrentWorkItem(): Promise<string | undefined> {
	try {
		// Use daily:path to get the actual daily note path, handles creation/template
		const pathResult = await exec("obsidian", ["vault=notes", "daily:path"], { timeout: 500 });
		const dailyPath = pathResult.stdout.trim();
		if (!dailyPath) return undefined;

		// Read the property from the daily note
		const result = await exec(
			"obsidian",
			["vault=notes", "property:read", "name=current_work_item", `path=${dailyPath}`],
			{ timeout: 1000 },
		);
		// Obsidian CLI writes errors to stdout, not stderr, so check for error messages
		const value = result.stdout.trim();
		if (!value || value.startsWith("Error:")) return undefined;
		return value;
	} catch {
		// Daily note may not exist yet, or Obsidian not running
		return undefined;
	}
}

function createWatchers(info: RepoInfo, onChange: () => void): FSWatcher[] {
	const watchers: FSWatcher[] = [];
	const safe = (path: string, opts: Parameters<typeof watch>[1] = {}) => {
		try {
			const w = watch(path, opts, () => onChange());
			w.on("error", () => {});
			watchers.push(w);
		} catch {}
	};
	if (info.jjOpHeadsDir) safe(info.jjOpHeadsDir);
	if (info.gitDir) {
		safe(join(info.gitDir, "HEAD"));
		safe(join(info.gitDir, "refs", "heads"), { recursive: true });
		safe(join(info.gitDir, "packed-refs"));
	}
	return watchers;
}

export default function (pi: ExtensionAPI) {
	let revInfo: string | undefined;
	let workItem: string | undefined;
	let repoName: string | undefined;
	let requestRender: (() => void) | undefined;
	let watchers: FSWatcher[] = [];
	let debounceTimer: NodeJS.Timeout | undefined;

	const refresh = async (cwd: string) => {
		const [nextRev, nextWork] = await Promise.all([
			getRevInfo(cwd),
			getCurrentWorkItem(),
		]);
		let changed = false;
		if (nextRev !== revInfo) {
			revInfo = nextRev;
			changed = true;
		}
		if (nextWork !== workItem) {
			workItem = nextWork;
			changed = true;
		}
		if (changed) {
			requestRender?.();
		}
	};

	pi.on("session_start", async (_event, ctx) => {
		// Initial refresh before mounting the footer so the first frame is correct.
		await refresh(ctx.cwd);

		const info = await findRepoInfo(ctx.cwd);
		repoName = basename(info.repoRoot ?? ctx.cwd);
		const scheduleRefresh = () => {
			if (debounceTimer) clearTimeout(debounceTimer);
			debounceTimer = setTimeout(() => {
				debounceTimer = undefined;
				void refresh(ctx.cwd);
			}, 120);
		};
		watchers = createWatchers(info, scheduleRefresh);

		ctx.ui.setFooter((tui, theme) => {
			requestRender = () => tui.requestRender();

			return {
				invalidate() {},
				render(width: number): string[] {
					const workItemText = workItem ?? "no work item";
					let leftText = `${repoName ?? basename(ctx.cwd)} • ${workItemText}`;
					if (revInfo) leftText = `${leftText} • ${revInfo}`;
					const sessionName = pi.getSessionName?.();
					if (sessionName) leftText = `${leftText} • ${sessionName}`;

					let input = 0;
					let output = 0;
					for (const e of ctx.sessionManager.getBranch()) {
						if (e.type === "message" && e.message.role === "assistant") {
							const m = e.message as AssistantMessage;
							input += m.usage.input;
							output += m.usage.output;
						}
					}
					const fmt = (n: number) => (n < 1000 ? `${n}` : `${(n / 1000).toFixed(1)}k`);
					const rightText = `↑${fmt(input)} ↓${fmt(output)}`;

					const left = theme.fg("dim", leftText);
					const rightDim = theme.fg("dim", rightText);
					const pad = " ".repeat(Math.max(2, width - visibleWidth(left) - visibleWidth(rightDim)));
					return [truncateToWidth(left + pad + rightDim, width)];
				},
			};
		});
	});

	pi.on("turn_end", async (_event, ctx) => {
		await refresh(ctx.cwd);
	});

	pi.on("session_shutdown", async () => {
		if (debounceTimer) {
			clearTimeout(debounceTimer);
			debounceTimer = undefined;
		}
		for (const w of watchers) {
			try {
				w.close();
			} catch {}
		}
		watchers = [];
	});
}
