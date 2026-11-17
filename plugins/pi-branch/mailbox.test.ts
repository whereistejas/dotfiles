import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import test from "node:test";
import "./test-hooks.ts";

const { findSession, liveSessions, Mailbox, register, send, unregister } = await import("./mailbox.ts");
const { Receiver } = await import("./receiver.ts");
const { inbox, post, saveMeta, sessionDir } = await import("./store.ts");

const session = (id: string, name: string, pid = process.pid) => ({ id: `0190-${id}`, name, cwd: `/work/${name}`, pid });
const assistant = (id: string, text: string) => ({ type: "message", id, message: { role: "assistant", content: [{ type: "text", text }] } });

/** A session with its own mailbox, recording what it shows. */
function endpoint(presence: ReturnType<typeof session>, tellOwner?: (text: string) => void) {
	const s = { idle: true, calls: [], entries: [] };
	const ctx = { isIdle: () => s.idle, sessionManager: { getBranch: () => s.entries } };
	const mailbox = new Mailbox({ sendMessage: (message, options) => s.calls.push({ message, options }) }, ctx, presence, tellOwner);
	return Object.assign(s, { ctx, mailbox, poll: () => mailbox.poll(ctx), settle: (aborted = false) => mailbox.onAgentSettled(ctx, aborted) });
}

test("only sessions whose process is alive are listed", () => {
	const dead = spawnSync("true").pid;
	register(session("alive", "alive"));
	register(session("dead", "dead", dead));
	const names = liveSessions().map((s) => s.name);
	assert.ok(names.includes("alive"));
	assert.ok(!names.includes("dead"));

	unregister(session("alive", "alive").id);
	assert.ok(!liveSessions().some((s) => s.name === "alive"));
	assert.ok(!fs.existsSync(sessionDir(session("alive", "alive").id)));
});

test("a session that stops keeps the messages waiting for it", () => {
	const to = session("offline1", "offline");
	register(to);
	send(session("sender02", "sender"), to, "For later");
	unregister(to.id);
	assert.ok(fs.existsSync(sessionDir(to.id)));
});

test("a target resolves by name or id, and nothing ambiguous resolves", () => {
	const sessions = [session("aaaa1111", "api"), session("bbbb2222", "web"), session("cccc3333", "web")];
	assert.equal(findSession("api", sessions).name, "api");
	assert.equal(findSession("0190-bbbb2222", sessions).id, "0190-bbbb2222");
	assert.equal(findSession("cccc3333", sessions).id, "0190-cccc3333");
	assert.throws(() => findSession("web", sessions), /more than one/);
	assert.throws(() => findSession("docs", sessions), /no live session/);
});

test("a message starts a turn in an idle session and steers a busy one, once", () => {
	const from = session("sender01", "sender");
	const to = session("target01", "target");
	let idle = true;
	const calls = [];
	const entries = [];
	const ctx = { isIdle: () => idle, sessionManager: { getBranch: () => entries } };
	const mailbox = new Mailbox({ sendMessage: (message, options) => calls.push({ message, options }) }, ctx, to);

	send(from, to, "Run the tests");
	mailbox.poll(ctx);
	assert.equal(calls.length, 1);
	assert.deepEqual(calls[0].options, { triggerTurn: true });
	assert.match(calls[0].message.content, /sender[\s\S]*Run the tests/);

	idle = false;
	send(from, to, "Also lint");
	mailbox.poll(ctx);
	assert.deepEqual(calls[1].options, { deliverAs: "steer" });

	mailbox.poll(ctx);
	assert.equal(calls.length, 2);

	const delivered = send(from, to, "Already seen before a reload");
	entries.push({ type: "custom_message", customType: calls[1].message.customType, details: { messageId: delivered } });
	new Mailbox({ sendMessage: (message, options) => calls.push({ message, options }) }, ctx, to).poll(ctx);
	assert.equal(calls.length, 2);
});

test("the recipient acknowledges a message, which shows in the sender without starting a turn", () => {
	const a = endpoint(session("acksend1", "asker"));
	const b = endpoint(session("ackrecv1", "helper"));

	send(session("acksend1", "asker"), session("ackrecv1", "helper"), "Push the stack");
	b.poll();
	a.poll();
	assert.equal(a.calls.length, 1);
	assert.deepEqual(a.calls[0].options, { triggerTurn: false });
	assert.match(a.calls[0].message.content, /helper[\s\S]*received[\s\S]*Push the stack/);

	b.poll();
	assert.equal(b.calls.length, 1);
});

test("the recipient's next answer goes back to the sender, which wakes for it, and nothing echoes back", () => {
	const asker = session("repsend1", "asker");
	const helper = session("reprecv1", "helper");
	const a = endpoint(asker);
	const b = endpoint(helper);
	b.entries.push(assistant("before", "An older answer"));

	send(asker, helper, "Push the stack");
	b.poll();
	b.settle();
	a.poll();
	assert.equal(a.calls.filter((c) => /answered/.test(c.message.content)).length, 0);

	b.entries.push(assistant("after", "Pushed all five"));
	b.settle();
	a.calls.length = 0;
	a.poll();
	assert.equal(a.calls.length, 1);
	assert.deepEqual(a.calls[0].options, { triggerTurn: true });
	assert.match(a.calls[0].message.content, /helper[\s\S]*answered[\s\S]*Pushed all five/);

	b.entries.push(assistant("later", "Unrelated work"));
	b.settle();
	a.calls.length = 0;
	a.poll();
	assert.equal(a.calls.length, 0);

	const before = b.calls.length;
	b.poll();
	assert.equal(b.calls.length, before);
});

test("a cancelled run tells the sender it was cancelled", () => {
	const asker = session("cansend1", "asker");
	const helper = session("canrecv1", "helper");
	const a = endpoint(asker);
	const b = endpoint(helper);

	send(asker, helper, "Push the stack");
	b.poll();
	b.settle(true);
	a.calls.length = 0;
	a.poll();
	assert.match(a.calls.find((c) => /answered/.test(c.message.content)).message.content, /cancelled/i);
});

test("a branch tells its owner, without waking it, that a session messaged it and it acknowledged", () => {
	const m = { id: "notified", name: "impl-x", flow: "tool", cwd: "/work", workerFile: "impl-x.jsonl", receiverFile: "owner.jsonl", createdAt: "now" };
	saveMeta(m);
	const b = endpoint(session("ownrecv1", "helper"), (text) => post(m.id, "to-receiver", { id: "notice-1", text, notice: true }));

	send(session("ownsend1", "asker"), session("ownrecv1", "helper"), "Push the stack");
	b.poll();
	assert.equal(inbox(m.id, "to-receiver").length, 1);

	const calls = [];
	const ctx = { isIdle: () => true, sessionManager: { getSessionFile: () => "owner.jsonl", getBranch: () => [] } };
	new Receiver({ sendMessage: (message, options) => calls.push({ message, options }) }, ctx).poll(ctx);
	assert.equal(calls.length, 1);
	assert.deepEqual(calls[0].options, { triggerTurn: false });
	assert.match(calls[0].message.content, /impl-x[\s\S]*asker[\s\S]*acknowledged[\s\S]*Push the stack/);
	assert.doesNotMatch(calls[0].message.content, /reported/);
});
