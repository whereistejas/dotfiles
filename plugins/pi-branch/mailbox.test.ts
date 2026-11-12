import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import test from "node:test";
import "./test-hooks.ts";

const { findSession, liveSessions, Mailbox, register, send, unregister } = await import("./mailbox.ts");
const { sessionDir } = await import("./store.ts");

const session = (id: string, name: string, pid = process.pid) => ({ id: `0190-${id}`, name, cwd: `/work/${name}`, pid });

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
	const mailbox = new Mailbox({ sendMessage: (message, options) => calls.push({ message, options }) }, ctx, to.id);

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
	new Mailbox({ sendMessage: (message, options) => calls.push({ message, options }) }, ctx, to.id).poll(ctx);
	assert.equal(calls.length, 2);
});
