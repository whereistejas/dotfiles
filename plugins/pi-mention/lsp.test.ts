import assert from "node:assert/strict";
import test from "node:test";

import { createSymbolCache, extractSymbolQuery, querySymbols, symbolRow } from "./lsp.ts";

const symbol = { name: "bar", kind: "Method", container: "Foo", file: "/repo/src/a.rs", line: 3, col: 5 };

test("extractSymbolQuery matches @@<query> at a word boundary only", () => {
	assert.equal(extractSymbolQuery("see @@Foo"), "Foo");
	assert.equal(extractSymbolQuery("@@"), "");
	assert.equal(extractSymbolQuery("a@@Foo"), undefined);
	assert.equal(extractSymbolQuery("@Foo"), undefined);
	assert.equal(extractSymbolQuery("@@Foo bar"), undefined);
});

test("symbolRow inserts a cwd-relative path:line:col with the qualified name", () => {
	assert.deepEqual(symbolRow(symbol, "/repo"), {
		tag: "Foo.bar",
		detail: "method src/a.rs:3",
		value: "src/a.rs:3:5 (Foo.bar)",
	});
	assert.equal(symbolRow({ ...symbol, file: "/other/b.rs", container: undefined }, "/repo").value, "../other/b.rs:3:5 (bar)");
	assert.equal(symbolRow({ ...symbol, line: undefined, col: undefined }, "/repo").value, "src/a.rs (Foo.bar)");
});

test("querySymbols polls Neovim until the request is done and drops duplicates", async () => {
	const replies = [{ done: false }, { done: false }, { done: true, symbols: [symbol, symbol] }];
	const requests = [];
	const call = async (fn, args) => {
		requests.push([fn, args]);
		return replies.shift();
	};
	const result = await querySymbols(call, { id: "1", cwd: "/repo", query: "bar" }, new AbortController().signal);
	assert.deepEqual(result, [symbol]);
	assert.equal(requests.length, 3);
	assert.ok(requests.every(([fn, args]) => fn === "symbols" && args.id === "1"));
});

test("querySymbols treats a non-array symbol list as empty", async () => {
	const call = async () => ({ done: true, symbols: {} });
	assert.deepEqual(await querySymbols(call, { id: "1", cwd: "/repo", query: "x" }, new AbortController().signal), []);
});

test("querySymbols gives up once aborted or when Neovim fails", async () => {
	const controller = new AbortController();
	const call = async () => {
		controller.abort();
		return { done: false };
	};
	assert.equal(await querySymbols(call, { id: "1", cwd: "/repo", query: "x" }, controller.signal), undefined);
	assert.equal(await querySymbols(async () => undefined, { id: "2", cwd: "/repo", query: "x" }, new AbortController().signal), undefined);
});

test("the symbol cache serves fresh hits and never caches failures", async () => {
	const answers = [undefined, [symbol]];
	let fetches = 0;
	const get = createSymbolCache(async () => {
		fetches++;
		return answers.shift();
	}, 60_000);
	const signal = new AbortController().signal;
	assert.equal(await get("bar", signal), undefined);
	assert.deepEqual(await get("bar", signal), [symbol]);
	assert.deepEqual(await get("bar", signal), [symbol]);
	assert.equal(fetches, 2);
});
