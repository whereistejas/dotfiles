import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import test from "node:test";

registerHooks({
	resolve(specifier, context, next) {
		if (specifier === "@earendil-works/pi-tui") {
			return { url: "data:text/javascript,export const fuzzyFilter=(xs,q,key)=>xs.filter(x=>key(x).includes(q)); export const visibleWidth=s=>s.length;", shortCircuit: true };
		}
		return next(specifier, context);
	},
});
const { default: extension } = await import("./index.ts");

for (const truncated of [false, true]) {
	test(`autocomplete bounds every subprocess and ${truncated ? "rejects truncated" : "parses complete"} records`, async () => {
		let start;
		let provider;
		const calls = [];
		const pi = {
			on: (name, handler) => { if (name === "session_start") start = handler; },
			async exec(command, args, options) {
				calls.push(options);
				const stdout = args[0] === "root" ? process.cwd() : args[0] === "bookmark" ? "topic\x1fabcdefgh\n" : args[0] === "log" ? "ijklmnop\x1f12345678\x1fChange\n" : "jj 1";
				return { code: 0, stdout, stderr: "", truncated: truncated && ["bookmark", "log"].includes(args[0]) };
			},
		};
		const current = { getSuggestions: async () => null, applyCompletion: () => {}, shouldTriggerFileCompletion: () => true };
		extension(pi);
		await start({}, { mode: "tui", cwd: process.cwd(), ui: { addAutocompleteProvider: (factory) => { provider = factory(current); } } });
		await new Promise(resolve => setImmediate(resolve));
		const result = await provider.getSuggestions(["@"], 0, 1, { signal: new AbortController().signal });
		assert.ok(calls.length >= 4);
		assert.ok(calls.every(options => options.maxBuffer > 0 && options.maxBuffer <= 1024 * 1024));
		if (truncated) assert.equal(result, null);
		else assert.deepEqual(result.items.map(item => item.value), ["@topic", "@ijklmnop"]);
	});
}

test("@@<query> lists LSP symbols from Neovim and stays out of jj completion", async (t) => {
	const previous = process.env.NVIM;
	process.env.NVIM = "test-socket";
	t.after(() => { if (previous === undefined) delete process.env.NVIM; else process.env.NVIM = previous; });

	let start;
	const providers = [];
	const pi = {
		on: (name, handler) => { if (name === "session_start") start = handler; },
		async exec(command, args) {
			if (command === "nvim") {
				const symbols = [{ name: "bar", kind: "Method", container: "Foo", file: `${process.cwd()}/src/a.rs`, line: 3, col: 5 }];
				return { code: 0, stdout: JSON.stringify({ done: true, symbols }), stderr: "", truncated: false };
			}
			return { code: 0, stdout: args[0] === "root" ? process.cwd() : "", stderr: "", truncated: false };
		},
	};
	const fallback = { getSuggestions: async () => ({ items: [{ value: "file", label: "file" }], prefix: "@" }), applyCompletion: () => {}, shouldTriggerFileCompletion: () => true };
	extension(pi);
	await start({}, { mode: "tui", cwd: process.cwd(), ui: { addAutocompleteProvider: (factory) => { providers.push(factory); } } });
	const provider = providers.reduce((current, factory) => factory(current), fallback);

	const result = await provider.getSuggestions(["see @@bar"], 0, 9, { signal: new AbortController().signal });
	assert.equal(result.prefix, "@@bar");
	assert.deepEqual(result.items.map(item => item.value), ["src/a.rs:3:5 (Foo.bar)"]);
});
