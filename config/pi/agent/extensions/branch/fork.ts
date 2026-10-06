import fs from "node:fs";
import path from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";

export const REPORT_TYPE = "branch-report";
export const MARKER_TYPE = "branch-marker";
export const TOOL_NAME = "branch";

type Block = { type: string; text?: string; id?: string; name?: string; redacted?: boolean; thinkingSignature?: string };
type Entry = {
	type: string;
	id: string;
	parentId: string | null;
	cwd?: string;
	targetId?: string;
	firstKeptEntryId?: string;
	customType?: string;
	replacement?: { content?: unknown } | null;
	message?: { role?: string; content?: unknown; toolName?: string; toolCallId?: string };
};

export interface ForkOptions {
	parentFile: string;
	leafId: string;
	cwd: string;
	/** Remove the parent's own branch orchestration, so a worker doesn't continue it. */
	forWorker: boolean;
	marker?: string;
}

/** Copies the active path of `parentFile` up to `leafId` into a new session file and returns its path. */
export function forkSession(opts: ForkOptions): string {
	// A separate manager: forking through the live one would redirect the running session to the fork.
	const manager = SessionManager.open(opts.parentFile, forksDir(opts.parentFile));
	const file = manager.createBranchedSession(opts.leafId);
	if (!file) throw new Error("pi did not create a fork file");
	if (opts.marker) manager.appendCustomMessageEntry(MARKER_TYPE, opts.marker, true);

	const [header, ...entries] = fs.existsSync(file)
		? fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as Entry)
		: ([manager.getHeader(), ...manager.getEntries()] as Entry[]);

	header.cwd = fs.realpathSync(opts.cwd);
	const kept = opts.forWorker ? dropOrchestration(entries) : entries;
	for (const entry of kept) stripSignedThinking(entry);
	fs.writeFileSync(file, `${[header, ...kept].map((e) => JSON.stringify(e)).join("\n")}\n`);
	return file;
}

export function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return (content as Block[]).flatMap((b) => (b.type === "text" && b.text !== undefined ? [b.text] : [])).join("\n");
}

/** Kept out of the parent's session directory so `pi -c` doesn't resume a fork. */
function forksDir(parentFile: string): string {
	return path.join(path.dirname(parentFile), path.basename(parentFile, ".jsonl"), "forks");
}

/** Signatures are bound to the session that produced them and are rejected after a fork. */
function stripSignedThinking(entry: Entry): void {
	const holder = entry.type === "context_edit" ? entry.replacement : entry.message;
	if (!holder || !Array.isArray(holder.content)) return;
	holder.content = (holder.content as Block[]).filter(
		(b) => b.type !== "redacted_thinking" && !(b.type === "thinking" && (b.redacted || b.thinkingSignature)),
	);
}

/** Drops `branch` calls and reports, and tool calls left without a result (the in-flight `branch` call's siblings). */
function dropOrchestration(entries: Entry[]): Entry[] {
	const answered = new Set(entries.map((e) => e.message?.toolCallId).filter(Boolean));
	const droppedCalls = new Set<string>();
	for (const { message } of entries) {
		if (message?.role !== "assistant" || !Array.isArray(message.content)) continue;
		message.content = (message.content as Block[]).filter((b) => {
			const drop = b.type === "toolCall" && (b.name === TOOL_NAME || !answered.has(b.id));
			if (drop && b.id) droppedCalls.add(b.id);
			return !drop;
		});
	}
	return relink(entries, ({ type, customType, message }) => {
		if (type === "custom_message") return customType !== REPORT_TYPE && customType !== MARKER_TYPE;
		if (message?.role === "toolResult") return !droppedCalls.has(message.toolCallId ?? "");
		if (message?.role === "assistant") return (message.content as Block[]).length > 0;
		return true;
	});
}

/** The fork is one linear path, so removing entries only needs the parent chain and id references redone. */
function relink(entries: Entry[], keep: (e: Entry) => boolean): Entry[] {
	const ids = new Set(entries.filter(keep).map((e) => e.id));
	const nextKept = new Map<string, string>();
	let next: string | undefined;
	for (const { id } of [...entries].reverse()) {
		if (ids.has(id)) next = id;
		else if (next) nextKept.set(id, next);
	}
	const out = entries.filter((e) => ids.has(e.id) && (!e.targetId || ids.has(e.targetId)));
	out.forEach((entry, i) => {
		entry.parentId = i === 0 ? null : out[i - 1].id;
		if (entry.firstKeptEntryId && !ids.has(entry.firstKeptEntryId)) {
			entry.firstKeptEntryId = nextKept.get(entry.firstKeptEntryId) ?? entry.id;
		}
	});
	return out;
}
