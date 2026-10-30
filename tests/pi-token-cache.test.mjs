import assert from "node:assert/strict";
import { test } from "node:test";

import { createTokenCache } from "../config/pi/agent/extensions/aigw/token-cache.mjs";

const signal = () => new AbortController().signal;
const token = (expires) => Buffer.from(JSON.stringify({ expires })).toString("base64");

test("reuses the token for five minutes, then refreshes", async () => {
	let now = 0;
	let calls = 0;
	const get = createTokenCache(async () => `token-${++calls}`, () => now);
	assert.equal(await get(signal()), "token-1");
	now = 299999;
	assert.equal(await get(signal()), "token-1");
	now = 300000;
	assert.equal(await get(signal()), "token-2");
	assert.equal(calls, 2);
});

test("refreshes before the token expires", async () => {
	let now = 0;
	let calls = 0;
	const get = createTokenCache(async () => { calls++; return token(60); }, () => now);
	await get(signal());
	now = 29999;
	await get(signal());
	assert.equal(calls, 1);
	now = 30000;
	await get(signal());
	assert.equal(calls, 2);
});

test("concurrent callers share one asynchronous lookup", async () => {
	let complete;
	let calls = 0;
	const get = createTokenCache(() => {
		calls++;
		return new Promise((resolve) => { complete = resolve; });
	});
	const first = get(signal());
	const second = get(signal());
	assert.equal(calls, 1);
	complete("fake-token");
	assert.deepEqual(await Promise.all([first, second]), ["fake-token", "fake-token"]);
});

test("failed refreshes are retried, not cached", async () => {
	let calls = 0;
	const get = createTokenCache(async () => {
		if (++calls === 1) throw new Error("fake failure");
		return "fake-token";
	});
	await assert.rejects(get(signal()), /fake failure/);
	assert.equal(await get(signal()), "fake-token");
	assert.equal(calls, 2);
});

test("cancellation prevents lookup and does not poison the cache", async () => {
	let calls = 0;
	const get = createTokenCache(async (signal) => {
		calls++;
		signal.throwIfAborted();
		return "fake-token";
	});
	const controller = new AbortController();
	controller.abort();
	await assert.rejects(get(controller.signal), { name: "AbortError" });
	assert.equal(calls, 0);
	assert.equal(await get(signal()), "fake-token");
});
