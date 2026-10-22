import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import { addWorkspace, removeWorkspace } from "./workspace.ts";

const env = { ...process.env, JJ_USER: "test", JJ_EMAIL: "test@example.com" };
const sh = (cwd: string, cmd: string, ...args: string[]) => execFileSync(cmd, args, { cwd, env, encoding: "utf8" });

const roots: string[] = [];
after(() => {
	for (const root of roots) fs.rmSync(root, { recursive: true, force: true });
});

function repo(files: Record<string, string> = {}): string {
	const root = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), "pi-branch-ws-"));
	roots.push(root);
	const dir = path.join(root, "repo");
	sh(root, "jj", "git", "init", "--colocate", "repo");
	for (const [file, text] of Object.entries(files)) {
		fs.mkdirSync(path.dirname(path.join(dir, file)), { recursive: true });
		fs.writeFileSync(path.join(dir, file), text);
	}
	sh(dir, "jj", "commit", "-m", "base");
	return dir;
}

const crate = (buildRs?: string) => ({
	".gitignore": "target/\n",
	"Cargo.toml": `[package]\nname = "demo"\nversion = "0.1.0"\nedition = "2021"\n`,
	"Cargo.lock": "version = 4\n\n[[package]]\nname = \"demo\"\nversion = \"0.1.0\"\n",
	"src/lib.rs": "pub fn one() -> u8 {\n    1\n}\n",
	...(buildRs ? { "build.rs": buildRs } : {}),
});

const warmupPid = (dir: string) => Number(fs.readFileSync(path.join(dir, "target", "agent-warmup.pid"), "utf8"));

function alive(pgid: number): boolean {
	try {
		process.kill(-pgid, 0);
		return true;
	} catch {
		return false;
	}
}

async function until(done: () => boolean, ms: number): Promise<void> {
	for (const end = Date.now() + ms; !done(); await new Promise((r) => setTimeout(r, 100))) {
		if (Date.now() > end) throw new Error("timed out");
	}
}

const workspaces = (dir: string) => sh(dir, "jj", "workspace", "list", "-T", 'name ++ "\\n"').trim().split("\n");

test("a Rust workspace starts from a clone of the source's target/ and warms it in the background", async () => {
	const dir = repo(crate());
	fs.mkdirSync(path.join(dir, "target"));
	fs.writeFileSync(path.join(dir, "target", "marker"), "built");

	const ws = await addWorkspace(dir, "rusty");

	const log = path.join(ws.dir, "target", "agent-warmup.log");
	assert.deepEqual(
		{ dir: ws.dir, marker: fs.readFileSync(path.join(ws.dir, "target", "marker"), "utf8"), briefNamesLog: ws.brief?.includes(log) },
		{ dir: `${dir}-rusty`, marker: "built", briefNamesLog: true },
	);
	await until(() => !alive(warmupPid(ws.dir)), 120_000);
	assert.match(fs.readFileSync(log, "utf8"), /Finished `test` profile[\s\S]*Executable/);
});

test("a workspace without Cargo.toml gets no warm-up", async () => {
	const dir = repo({ "README.md": "hi\n" });

	const ws = await addWorkspace(dir, "plain");

	assert.deepEqual({ brief: ws.brief, target: fs.existsSync(path.join(ws.dir, "target")) }, { brief: undefined, target: false });
});

test("removing a workspace keeps its uncommitted edits as a commit, forgets it and deletes its folder", async () => {
	const dir = repo({ "README.md": "hi\n" });
	const ws = await addWorkspace(dir, "gone");
	fs.writeFileSync(path.join(ws.dir, "edit.txt"), "kept\n");

	await removeWorkspace(ws.dir);

	const heads = sh(dir, "jj", "log", "--no-graph", "-r", "heads(all())", "-T", 'commit_id ++ "\\n"').trim().split("\n");
	const kept = heads.some((rev) => sh(dir, "jj", "file", "list", "-r", rev).includes("edit.txt"));
	assert.deepEqual({ exists: fs.existsSync(ws.dir), workspaces: workspaces(dir), kept }, { exists: false, workspaces: ["default"], kept: true });
});

test("removing a workspace stops its warm-up build first", async () => {
	const dir = repo(crate("fn main() {\n    std::thread::sleep(std::time::Duration::from_secs(60));\n}\n"));
	const ws = await addWorkspace(dir, "busy");
	const pgid = warmupPid(ws.dir);
	await until(() => fs.readFileSync(path.join(ws.dir, "target", "agent-warmup.log"), "utf8").includes("Compiling demo"), 60_000);

	await removeWorkspace(ws.dir);

	assert.deepEqual({ alive: alive(pgid), exists: fs.existsSync(ws.dir) }, { alive: false, exists: false });
});

test("the default workspace is never removed", async () => {
	const dir = repo({ "README.md": "hi\n" });

	await assert.rejects(removeWorkspace(dir));

	assert.deepEqual({ exists: fs.existsSync(path.join(dir, "README.md")), workspaces: workspaces(dir) }, { exists: true, workspaces: ["default"] });
});
