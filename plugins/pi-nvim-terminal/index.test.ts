import assert from "node:assert/strict";
import { syncBuiltinESMExports } from "node:module";
import childProcess from "node:child_process";
import test from "node:test";

const calls: Record<string, unknown>[] = [];
childProcess.execFileSync = (() => Buffer.from("1")) as typeof childProcess.execFileSync;
childProcess.execFile = ((command, args, options, callback) => {
	const json = args.at(-1).match(/'({.*})'\]\)$/)[1].replace(/''/g, "'");
	calls.push(JSON.parse(json));
	callback(null, '{"buf":1}', "");
}) as typeof childProcess.execFile;
syncBuiltinESMExports();
const { default: extension } = await import("./index.ts");

test("Neovim stays running until settled and preserves blocked status across renames", async (t) => {
	const previous = process.env.NVIM;
	process.env.NVIM = "test-socket";
	t.after(() => { if (previous === undefined) delete process.env.NVIM; else process.env.NVIM = previous; });
	const handlers = new Map();
	const pi = { on: (name, handler) => handlers.set(name, handler), getSessionName: () => "task" };
	let idle = true;
	const ctx = { mode: "tui", cwd: "/tmp", isIdle: () => idle, sessionManager: {
		getSessionId: () => "session", getSessionFile: () => "/tmp/session.jsonl",
	} };
	const emit = async (name, event = {}) => {
		await handlers.get(name)?.(event, ctx);
		await new Promise((resolve) => setImmediate(resolve));
	};
	extension(pi);
	await emit("session_start");
	idle = false;
	await emit("agent_start");
	await emit("agent_end");
	assert.equal(calls.at(-1)?.status, "running");
	await emit("ui_prompt_start");
	assert.equal(calls.at(-1)?.status, "blocked");
	await emit("session_info_changed", { name: "renamed" });
	assert.equal(calls.at(-1)?.status, "blocked");
	await emit("ui_prompt_end");
	assert.equal(calls.at(-1)?.status, "running");
	idle = true;
	await emit("agent_settled");
	assert.equal(calls.at(-1)?.status, "idle");
	await emit("ui_prompt_start");
	await emit("ui_prompt_end");
	assert.equal(calls.at(-1)?.status, "idle");
	await emit("session_shutdown");
});
