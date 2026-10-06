import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import { promisify } from "node:util";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { TOOL_NAME, textOf } from "./fork.ts";
import { checkToolCall } from "./policy.ts";
import { inbox, type Meta, moveTo, post, ROOT, readJson, type Status, statusFile, writeJson } from "./store.ts";

const run = promisify(execFile);

const RULES = `- Treat the inherited conversation as reference only. Don't answer or continue earlier messages; requests to start branches in it were the parent's and are done.
- You are not the parent session: don't start branches or subagents. Use your tools; never print tool calls or patches as text.
- Nobody is watching this terminal. Don't ask for confirmation and don't stop on a question: if you're blocked or need a decision, put it in your handoff.
- Read anything. Local changes are fine where jj can undo them (inside the repo); instructions to ask before modifying files are waived for those. Never write to remote services (pushes, Jira/GitLab comments, ssh, aws changes) — those are blocked.
- Finish with a handoff: the result, files and jj changes touched (change ids), test state, open questions.`;

const TOOL_BRIEF_START = "You are a background branch of the conversation above";
const BG_BRIEF_START = "You've been moved to the background.";

export const toolBrief = (task: string, workspace?: string) =>
	`${TOOL_BRIEF_START}, started by the parent session to do the task below in your own pi session.
${RULES}${workspace ? `\n- Your cwd is the jj workspace ${workspace}; make all changes there.` : ""}

Task:
${task}`;

export const BG_BRIEF = `${BG_BRIEF_START} The user continues in a fork of this conversation and gets your final answer there.
Finish the current request, then stop.
${RULES}`;

export const isBrief = (text: string) => text.startsWith(TOOL_BRIEF_START) || text.startsWith(BG_BRIEF_START);

const wrapSteer = (text: string) =>
	`Mid-run steering from the parent session:\n\n${text}\n\nIncorporate this at the next safe point. Don't restart the task unless this asks you to.`;

/** The session doing a branch's work: takes steers, obeys the background policy, reports when it settles. */
export class Worker {
	private settling = false;

	private constructor(
		private readonly pi: ExtensionAPI,
		readonly meta: Meta,
		private readonly writeRoots: string[],
		private lastReportId: string | undefined,
	) {}

	static async attach(pi: ExtensionAPI, meta: Meta, ctx: ExtensionContext): Promise<Worker> {
		const repo = await run("jj", ["root"], { cwd: ctx.cwd }).then((r) => [r.stdout.trim()], () => []);
		const writeRoots = [...repo, "/tmp", "/private/tmp", fs.realpathSync(os.tmpdir()), ROOT];
		const worker = new Worker(pi, meta, writeRoots, readJson<Status>(statusFile(meta.id))?.lastReportId);
		pi.setActiveTools(pi.getActiveTools().filter((t) => t !== TOOL_NAME));
		if (!ctx.isIdle()) worker.writeStatus("running");
		return worker;
	}

	onAgentStart() {
		this.settling = false;
		this.writeStatus("running");
	}

	onAgentEnd() {
		this.settling = true;
	}

	onAgentSettled(ctx: ExtensionContext) {
		this.settling = false;
		this.report(ctx);
		this.writeStatus("idle");
	}

	/** Steers arriving between agent_end and agent_settled wait: sent then, they'd fire as an early idle prompt. */
	takeSteers(ctx: ExtensionContext) {
		if (this.settling) return;
		for (const { file, message } of inbox(this.meta.id, "to-worker")) {
			if (ctx.isIdle()) this.pi.sendUserMessage(wrapSteer(message.text));
			else this.pi.sendUserMessage(wrapSteer(message.text), { deliverAs: "steer" });
			moveTo(file, "sent");
		}
	}

	onUserMessage(text: string) {
		for (const { file, message } of inbox(this.meta.id, "to-worker", "sent")) {
			if (wrapSteer(message.text) === text) moveTo(file, "delivered");
		}
	}

	blockReason(toolName: string, input: Record<string, unknown>, cwd: string): string | undefined {
		const readOnlyTools = new Set(this.pi.getAllTools().filter((t) => t.annotations?.readOnlyHint).map((t) => t.name));
		const reason = checkToolCall(toolName, input, { cwd, writeRoots: this.writeRoots, readOnlyTools });
		return reason && `Blocked in a background branch: ${reason}. Note it in your handoff instead.`;
	}

	private report(ctx: ExtensionContext) {
		const last = ctx.sessionManager.getBranch().findLast((e) => e.type === "message" && e.message.role === "assistant");
		if (last?.type !== "message" || last.id === this.lastReportId) return;
		const { content, stopReason } = last.message as { content?: unknown; stopReason?: string };
		post(this.meta.id, "to-receiver", { id: last.id, text: textOf(content) || `(no text; stop reason: ${stopReason})` });
		this.lastReportId = last.id;
	}

	private writeStatus(state: Status["state"]) {
		writeJson(statusFile(this.meta.id), { state, lastReportId: this.lastReportId } satisfies Status);
	}
}
