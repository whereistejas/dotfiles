import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { closeTerminal, openTerminal } from "./nvim.ts";

const NAME = "doomed";
const FILE = "/sessions/doomed.jsonl";

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
	const { buf } = await openTerminal({ name: NAME, cmd: ["sleep", "60"], cwd: tmp, show: false });
	const pid = Number(expr(`jobpid(getbufvar(${buf}, '&channel'))`));

	await closeTerminal({ name: NAME, buf, file: FILE });

	await new Promise((r) => setTimeout(r, 300));
	assert.deepEqual({ exists: expr(`bufexists(${buf})`), alive: alive(pid) }, { exists: "0", alive: false });
});

test("a terminal that exits after its branch's folder is gone writes no exit file and raises no error", async () => {
	const branchDir = fs.mkdtempSync(path.join(tmp, "branch-"));
	const exitFile = path.join(branchDir, "exit.json");
	const { buf } = await openTerminal({ name: NAME, cmd: ["sleep", "60"], cwd: tmp, exitFile, show: false });
	fs.rmSync(branchDir, { recursive: true });

	await closeTerminal({ name: NAME, buf, file: FILE });

	await new Promise((r) => setTimeout(r, 300));
	assert.deepEqual({ exitFile: fs.existsSync(exitFile), errmsg: expr("v:errmsg") }, { exitFile: false, errmsg: "" });
});

test("closing a buffer that is already gone succeeds", async () => {
	const { buf } = await openTerminal({ name: NAME, cmd: ["sleep", "60"], cwd: tmp, show: false });
	await closeTerminal({ name: NAME, buf, file: FILE });

	await closeTerminal({ name: NAME, buf, file: FILE });
});

/** A terminal running `sleep`, as nvim recreates one when it restores a session. */
function plainTerminal(): number {
	return Number(expr(`luaeval('(function() local b = vim.api.nvim_create_buf(true, false) vim.api.nvim_buf_call(b, function() vim.fn.jobstart({ "sleep", "60" }, { term = true }) end) return b end)()')`));
}

test("closing a branch wipes the terminal its pi was restored into", async () => {
	const restored = plainTerminal();
	expr(`luaeval('(function() vim.b[${restored}].pi_session = { file = "${FILE}" } end)()')`);

	await closeTerminal({ name: NAME, buf: restored + 100, file: FILE });

	assert.equal(expr(`bufexists(${restored})`), "0");
});

test("closing a branch leaves another terminal that took its old buffer number alone", async () => {
	const other = plainTerminal();

	await closeTerminal({ name: NAME, buf: other, file: FILE });

	assert.equal(expr(`bufexists(${other})`), "1");
});
