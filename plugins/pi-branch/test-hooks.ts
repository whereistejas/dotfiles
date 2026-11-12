import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { registerHooks, stripTypeScriptTypes } from "node:module";
import test from "node:test";

/** Lets tests load worker.ts, receiver.ts, mailbox.ts and store.ts: stubs fork.ts's pi import and keeps branch storage in a temporary directory. */
export const root = fs.mkdtempSync(path.join(os.tmpdir(), "pi-branch-test-"));

registerHooks({
	resolve(specifier, context, next) {
		if (specifier === "./fork.ts") {
			return { url: "data:text/javascript,export const REPORT_TYPE='branch-report'; export const TOOL_NAME='branch'; export const textOf=c=>typeof c==='string'?c:(c??[]).filter(b=>b.type==='text').map(b=>b.text).join('\\n');", shortCircuit: true };
		}
		return next(specifier, context);
	},
	load(url, context, next) {
		if (/\/(worker|receiver|mailbox|store)\.ts$/.test(url)) {
			let source = fs.readFileSync(new URL(url), "utf8");
			if (url.endsWith("/store.ts")) source = source.replace('path.join(os.homedir(), ".pi", "agent", "branches")', JSON.stringify(root));
			return { format: "module", source: stripTypeScriptTypes(source, { mode: "transform" }), shortCircuit: true };
		}
		return next(url, context);
	},
});

test.after(() => fs.rmSync(root, { recursive: true, force: true }));
