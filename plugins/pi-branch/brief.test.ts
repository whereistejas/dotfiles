import assert from "node:assert/strict";
import test from "node:test";
import "./test-hooks.ts";

const { isBrief, toolBrief, Worker } = await import("./worker.ts");

const meta = (id: string, extra = {}) => ({ id, name: id, flow: "tool", cwd: process.cwd(), workerFile: `${id}.jsonl`, receiverFile: "parent.jsonl", createdAt: "now", ...extra });
const ctx = { cwd: process.cwd(), isIdle: () => true, sessionManager: { getBranch: () => [] } };

function piWith(tools: string[]) {
	let active = tools;
	return { getActiveTools: () => active, setActiveTools: (t: string[]) => { active = t; }, getAllTools: () => [], active: () => active };
}

test("a forked brief points at the inherited conversation", () => {
	const brief = toolBrief("Do it");
	assert.ok(isBrief(brief));
	assert.match(brief, /inherited conversation/);
});

test("a fresh brief stands alone", () => {
	const brief = toolBrief("Do it", undefined, { fresh: true });
	assert.ok(isBrief(brief));
	assert.doesNotMatch(brief, /inherited conversation|conversation above/);
	assert.match(brief, /Task:\nDo it$/);
});

test("a worker loses the branch tool unless it may start subagents", async () => {
	const plain = piWith(["read", "branch"]);
	await Worker.attach(plain, meta("plain"), ctx);
	assert.deepEqual(plain.active(), ["read"]);

	const nesting = piWith(["read", "branch"]);
	await Worker.attach(nesting, meta("nesting", { subagents: true }), ctx);
	assert.deepEqual(nesting.active(), ["read", "branch"]);
});

test("a worker that may start subagents is told to use fresh branches", () => {
	const brief = toolBrief("Do it", undefined, { subagents: true });
	assert.match(brief, /fresh: true/);
	assert.doesNotMatch(brief, /pi -p/);
});
