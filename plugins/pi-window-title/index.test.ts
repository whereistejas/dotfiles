import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import test from "node:test";

registerHooks({
	resolve(specifier, context, next) {
		if (specifier === "@earendil-works/pi-ai") {
			return { url: "data:text/javascript,export const getModel = () => undefined; export const complete = () => {};", shortCircuit: true };
		}
		return next(specifier, context);
	},
});
const { default: extension } = await import("./index.ts");

test("the title spinner survives low-level agent_end and stops when settled", async (t) => {
	t.mock.timers.enable({ apis: ["setInterval", "setTimeout"] });
	const handlers = new Map();
	const titles: string[] = [];
	const pi = { on: (name, handler) => handlers.set(name, handler), getSessionName: () => "task" };
	const ctx = { ui: { setTitle: (title) => titles.push(title) }, sessionManager: { getBranch: () => [] } };
	extension(pi);
	t.after(() => handlers.get("session_shutdown")({}, ctx));

	await handlers.get("agent_start")({}, ctx);
	t.mock.timers.tick(80);
	assert.match(titles.at(-1)!, /^⠋ /);
	await handlers.get("agent_end")?.({}, ctx);
	t.mock.timers.tick(80);
	assert.match(titles.at(-1)!, /^⠙ /);
	await handlers.get("agent_settled")({}, ctx);
	assert.doesNotMatch(titles.at(-1)!, /^[⠋⠙] /);
	const count = titles.length;
	t.mock.timers.tick(160);
	assert.equal(titles.length, count);
});
