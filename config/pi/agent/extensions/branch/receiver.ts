import fs from "node:fs";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { REPORT_TYPE } from "./fork.ts";
import { type Exit, exitFile, inbox, listMetas, type Meta, readJson, type Status, statusFile } from "./store.ts";

const WAKE_TIMEOUT_MS = 10_000;
const PREVIEW_BYTES = 4096;

/** The session a branch reports to: posts each report once, waking the agent if it's idle. */
export class Receiver {
	private readonly branches: Meta[];
	private readonly delivered = new Set<string>();
	private wakeUntil = 0;

	constructor(
		private readonly pi: ExtensionAPI,
		ctx: ExtensionContext,
	) {
		const file = ctx.sessionManager.getSessionFile();
		this.branches = file ? listMetas().filter((m) => m.receiverFile === file) : [];
		for (const entry of ctx.sessionManager.getBranch()) {
			if (entry.type !== "custom_message" || entry.customType !== REPORT_TYPE) continue;
			const reportId = (entry.details as { reportId?: string } | undefined)?.reportId;
			if (reportId) this.delivered.add(reportId);
		}
	}

	get waiting(): boolean {
		return this.branches.length > 0;
	}

	add(meta: Meta) {
		this.branches.push(meta);
	}

	onAgentStart() {
		this.wakeUntil = 0;
	}

	poll(ctx: ExtensionContext) {
		for (const meta of this.branches) {
			for (const { file, message } of inbox(meta.id, "to-receiver")) {
				this.deliver(ctx, meta, message.id, preview(message.text));
				fs.unlinkSync(file);
			}
			const exit = readJson<Exit>(exitFile(meta.id));
			if (exit && !readJson<Status>(statusFile(meta.id))?.lastReportId) {
				const tail = exit.tail.filter((l) => l.trim()).slice(-20).join("\n");
				this.deliver(ctx, meta, `exit-${meta.id}`, `Its terminal exited (code ${exit.code}) before it reported. Last lines:\n\n${tail}`);
			}
		}
	}

	private deliver(ctx: ExtensionContext, meta: Meta, reportId: string, body: string) {
		if (this.delivered.has(reportId)) return;
		this.delivered.add(reportId);
		const message = {
			customType: REPORT_TYPE,
			content: `Branch **${meta.name}** reported:\n\n${body}\n\nFull transcript: ${meta.workerFile}`,
			display: true,
			details: { branchId: meta.id, reportId },
		};
		if (!ctx.isIdle() || Date.now() < this.wakeUntil) {
			this.pi.sendMessage(message, { deliverAs: "steer" });
			return;
		}
		// A turn started by sendMessage skips before_agent_start hooks, so wake with a user message instead.
		this.pi.sendMessage(message, { triggerTurn: false });
		this.pi.sendUserMessage(`Branch ${meta.name} reported (see above).`, { deliverAs: "steer" });
		this.wakeUntil = Date.now() + WAKE_TIMEOUT_MS;
	}
}

function preview(text: string): string {
	const bytes = Buffer.from(text);
	if (bytes.length <= PREVIEW_BYTES) return text;
	return `${bytes.subarray(0, PREVIEW_BYTES).toString().replace(/\uFFFD+$/, "")}\n…[truncated; the full answer is in the transcript]`;
}
