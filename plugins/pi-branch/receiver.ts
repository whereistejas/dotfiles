import fs from "node:fs";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { REPORT_TYPE } from "./fork.ts";
import { type Exit, exitFile, inbox, listMetas, type Meta, readJson, type Status, statusFile } from "./store.ts";

const PREVIEW_BYTES = 4096;

/** The session a branch reports to: posts each report once, waking the agent if it's idle. */
export class Receiver {
	private readonly branches: Meta[];
	private readonly delivered = new Set<string>();

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

	remove(id: string) {
		const at = this.branches.findIndex((m) => m.id === id);
		if (at >= 0) this.branches.splice(at, 1);
	}

	poll(ctx: ExtensionContext) {
		for (const meta of this.branches) {
			for (const { file, message } of inbox(meta.id, "to-receiver")) {
				if (message.notice) this.deliver(ctx, meta, message.id, message.text, true);
				else this.deliver(ctx, meta, message.id, preview(message.text));
				fs.unlinkSync(file);
			}
			const exit = readJson<Exit>(exitFile(meta.id));
			if (exit && !readJson<Status>(statusFile(meta.id))?.lastReportId) {
				const tail = exit.tail.filter((l) => l.trim()).slice(-20).join("\n");
				this.deliver(ctx, meta, `exit-${meta.id}`, `Its terminal exited (code ${exit.code}) before it reported. Last lines:\n\n${tail}`);
			}
		}
	}

	/** A notice is informational: it doesn't start a turn, and lands after the current one if there is one. */
	private deliver(ctx: ExtensionContext, meta: Meta, reportId: string, body: string, notice = false) {
		if (this.delivered.has(reportId)) return;
		this.delivered.add(reportId);
		const message = {
			customType: REPORT_TYPE,
			content: notice ? `Branch **${meta.name}** ${body}` : `Branch **${meta.name}** reported:\n\n${body}\n\nFull transcript: ${meta.workerFile}`,
			display: true,
			details: { branchId: meta.id, reportId },
		};
		if (notice) {
			this.pi.sendMessage(message, { triggerTurn: false });
			return;
		}
		if (!ctx.isIdle()) {
			this.pi.sendMessage(message, { deliverAs: "steer" });
			return;
		}
		this.pi.sendMessage(message, { triggerTurn: true });
	}
}

export function preview(text: string, max = PREVIEW_BYTES): string {
	const bytes = Buffer.from(text);
	if (bytes.length <= max) return text;
	return `${bytes.subarray(0, max).toString().replace(/\uFFFD+$/, "")}\n…[truncated; the full answer is in the transcript]`;
}
