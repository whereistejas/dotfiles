import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { closeBuffer, openTerminal } from "./nvim.ts";

let nvim: ChildProcess;
let tmp: string;

const expr = (e: string) =>
	execFileSync("nvim", ["--clean", "--headless", "--server", process.env.NVIM!, "--remote-expr", e], { encoding: "utf8" }).trim();

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

before(async () => {
	tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pi-branch-nvim-"));
	process.env.NVIM = path.join(tmp, "nvim.sock");
	nvim = spawn("nvim", ["--clean", "--headless", "--listen", process.env.NVIM], { stdio: "ignore" });
	while (!fs.existsSync(process.env.NVIM)) await new Promise((r) => setTimeout(r, 50));
});

after(() => {
	nvim.kill();
	fs.rmSync(tmp, { recursive: true, force: true });
});

test("closing a branch wipes its terminal buffer and stops what runs in it", async () => {
	const { buf } = await openTerminal({ name: "doomed", cmd: ["sleep", "60"], cwd: tmp, show: false });
	const pid = Number(expr(`jobpid(getbufvar(${buf}, '&channel'))`));

	await closeBuffer(buf);

	await new Promise((r) => setTimeout(r, 300));
	assert.deepEqual({ exists: expr(`bufexists(${buf})`), alive: alive(pid) }, { exists: "0", alive: false });
});

test("a terminal that exits after its branch's folder is gone writes no exit file and raises no error", async () => {
	const branchDir = fs.mkdtempSync(path.join(tmp, "branch-"));
	const exitFile = path.join(branchDir, "exit.json");
	const { buf } = await openTerminal({ name: "late", cmd: ["sleep", "60"], cwd: tmp, exitFile, show: false });
	fs.rmSync(branchDir, { recursive: true });

	await closeBuffer(buf);

	await new Promise((r) => setTimeout(r, 300));
	assert.deepEqual({ exitFile: fs.existsSync(exitFile), errmsg: expr("v:errmsg") }, { exitFile: false, errmsg: "" });
});

test("closing a buffer that is already gone succeeds", async () => {
	const { buf } = await openTerminal({ name: "twice", cmd: ["sleep", "60"], cwd: tmp, show: false });
	await closeBuffer(buf);

	await closeBuffer(buf);
});
