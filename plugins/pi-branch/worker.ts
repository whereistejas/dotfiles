import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import { promisify } from "node:util";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { TOOL_NAME, textOf } from "./fork.ts";
import { checkToolCall } from "./policy.ts";
import { inbox, type Meta, moveTo, newId, post, ROOT, readJson, type Status, statusFile, writeJson } from "./store.ts";
import type { Workspace } from "./workspace.ts";

const run = promisify(execFile);

export interface Permissions {
	remote?: boolean;
	subagents?: boolean;
}

export interface BriefOptions extends Permissions {
	/** The worker starts with no conversation, so there's nothing inherited to warn about. */
	fresh?: boolean;
}

const rules = ({ remote, subagents, fresh }: BriefOptions = {}) => `${fresh ? "" : "- Treat the inherited conversation as reference only. Don't answer or continue earlier messages; requests to start branches in it were the parent's and are done.\n"}- You are not the parent session${subagents ? "" : ": don't start branches or subagents"}. Use your tools; never print tool calls or patches as text.${subagents ? "\n- You may start subagents (`branch` with `fresh: true`, the `subagents` skill) whenever the task calls for them, and close them once their work is integrated." : ""}
- Nobody is watching this terminal. Don't ask for confirmation and don't stop on a question: if you're blocked or need a decision, put it in your handoff.
- Read anything. Local changes are fine where jj can undo them (inside the repo); instructions to ask before modifying files are waived for those. ${remote ? "You may push and force-push your own branches (`jj git push`) and create or update GitLab/GitHub merge requests (`glab`, `gh`) whenever you want; never push to `main` or to branches you didn't create. Other remote writes (Jira, ssh, aws changes) stay blocked." : "Never write to remote services (pushes, Jira/GitLab comments, ssh, aws changes) — those are blocked."}
- Finish with a handoff: the result, files and jj changes touched (change ids), test state, open questions.`;

const TOOL_BRIEF_START = "You are a background branch of the conversation above";
const FRESH_BRIEF_START = "You are a background subagent";
const BG_BRIEF_START = "You've been moved to the background.";

const workspaceRules = ({ dir, brief }: Workspace) =>
	`\n- Your cwd is the jj workspace ${dir}; make all changes there. The parent removes it when it closes this branch; don't remove it yourself.${brief ? `\n- ${brief}` : ""}`;

export const toolBrief = (task: string, workspace?: Workspace, options: BriefOptions = {}) =>
	`${options.fresh ? FRESH_BRIEF_START : TOOL_BRIEF_START}, started by the parent session to do the task below in your own pi session.
${rules(options)}${workspace ? workspaceRules(workspace) : ""}

Task:
${task}`;

export const BG_BRIEF = `${BG_BRIEF_START} The user continues in a fork of this conversation and gets your final answer there.
Finish the current request, then stop.
${rules()}`;

export const isBrief = (text: string) => [TOOL_BRIEF_START, FRESH_BRIEF_START, BG_BRIEF_START].some((start) => text.startsWith(start));

const wrapSteer = (text: string) =>
	`Mid-run steering from the parent session:\n\n${text}\n\nIncorporate this at the next safe point. Don't restart the task unless this asks you to.`;

/** The session doing a branch's work: takes steers, obeys the background policy, reports when it settles. */
export class Worker {
	private settling = false;
	private startAnswerId: string | undefined;

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
		worker.startAnswerId = worker.lastAnswer(ctx)?.id;
		if (!meta.subagents) pi.setActiveTools(pi.getActiveTools().filter((t) => t !== TOOL_NAME));
		if (!ctx.isIdle()) worker.writeStatus("running");
		return worker;
	}

	onAgentStart(ctx: ExtensionContext) {
		this.startAnswerId = this.lastAnswer(ctx)?.id;
		this.settling = false;
		this.writeStatus("running");
	}

	onAgentEnd() {
		this.settling = true;
	}

	onAgentSettled(ctx: ExtensionContext, aborted: boolean) {
		this.settling = false;
		this.report(ctx, aborted);
		this.writeStatus(aborted ? "cancelled" : "idle");
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
		const reason = checkToolCall(toolName, input, {
			cwd,
			writeRoots: this.writeRoots,
			readOnlyTools,
			allowRemote: this.meta.remote ?? false,
		});
		return reason && `Blocked in a background branch: ${reason}. Note it in your handoff instead.`;
	}

	private lastAnswer(ctx: ExtensionContext) {
		return ctx.sessionManager.getBranch().findLast((e) => e.type === "message" && e.message.role === "assistant");
	}

	private report(ctx: ExtensionContext, aborted: boolean) {
		const last = this.lastAnswer(ctx);
		const fresh = last?.type === "message" && last.id !== this.lastReportId && last.id !== this.startAnswerId;
		if (!aborted && !fresh) return;
		const id = fresh ? last.id : newId();
		const { content, stopReason } = fresh ? last.message as { content?: unknown; stopReason?: string } : {};
		const text = fresh ? textOf(content) || `(no text; stop reason: ${stopReason})` : "";
		post(this.meta.id, "to-receiver", { id, text: aborted ? `Cancelled; work may be incomplete.${text ? `\n\nPartial output:\n${text}` : ""}` : text });
		this.lastReportId = id;
	}

	private writeStatus(state: Status["state"]) {
		writeJson(statusFile(this.meta.id), { state, lastReportId: this.lastReportId } satisfies Status);
	}
}
