import assert from "node:assert/strict";
import test from "node:test";
import "./test-hooks.ts";

const { Worker } = await import("./worker.ts");
const { Receiver } = await import("./receiver.ts");
const { inbox, post, saveMeta, readJson, statusFile } = await import("./store.ts");

const meta = (id: string) => ({ id, name: id, flow: "tool", cwd: process.cwd(), workerFile: `${id}.jsonl`, receiverFile: "parent.jsonl", createdAt: "now" });
const assistant = (id: string, text: string) => ({ type: "message", id, message: { role: "assistant", content: [{ type: "text", text }], stopReason: "stop" } });
const pi = { getActiveTools: () => [], setActiveTools: () => {}, getAllTools: () => [] };

test("cancelled workers report cancellation without reusing an earlier answer", async () => {
	const m = meta("cancelled");
	const entries = [assistant("old", "Earlier completed task")];
	const ctx = { cwd: process.cwd(), isIdle: () => true, sessionManager: { getBranch: () => entries } };
	const worker = await Worker.attach(pi, m, ctx);
	worker.onAgentStart(ctx);
	worker.onAgentSettled(ctx, true);
	const reports = inbox(m.id, "to-receiver");
	assert.equal(reports.length, 1);
	assert.match(reports[0].message.text, /cancelled/i);
	assert.doesNotMatch(reports[0].message.text, /Earlier completed task/);
	assert.equal(readJson(statusFile(m.id)).state, "cancelled");
});

test("cancelled workers label partial output and can later finish normally", async () => {
	const m = meta("partial");
	const entries = [];
	const ctx = { cwd: process.cwd(), isIdle: () => true, sessionManager: { getBranch: () => entries } };
	const worker = await Worker.attach(pi, m, ctx);
	worker.onAgentStart(ctx);
	entries.push(assistant("partial-answer", "Half done"));
	worker.onAgentSettled(ctx, true);
	assert.match(inbox(m.id, "to-receiver")[0].message.text, /cancelled[\s\S]*Half done/i);
	worker.onAgentStart(ctx);
	entries.push(assistant("final-answer", "Finished"));
	worker.onAgentSettled(ctx, false);
	assert.equal(inbox(m.id, "to-receiver").find(({ message }) => message.id === "final-answer").message.text, "Finished");
	assert.equal(readJson(statusFile(m.id)).state, "idle");
});

test("simultaneous reports start one run and queue the rest during startup", () => {
	const metas = [meta("one"), meta("two")];
	for (const m of metas) { saveMeta(m); post(m.id, "to-receiver", { id: m.id, text: "Done" }); }
	let idle = true;
	const calls = [];
	const ctx = { isIdle: () => idle, sessionManager: { getSessionFile: () => "parent.jsonl", getBranch: () => [] } };
	const receiver = new Receiver({ sendMessage(message, options) { calls.push({ message, options }); if (options.triggerTurn) idle = false; } }, ctx);
	receiver.poll(ctx);
	assert.deepEqual(calls.map(c => c.options), [{ triggerTurn: true }, { deliverAs: "steer" }]);
	assert.equal(inbox("one", "to-receiver").length, 0);
	assert.equal(inbox("two", "to-receiver").length, 0);

	idle = true;
	post("one", "to-receiver", { id: "again", text: "Another result" });
	receiver.poll(ctx);
	assert.deepEqual(calls.at(-1).options, { triggerTurn: true });
});
