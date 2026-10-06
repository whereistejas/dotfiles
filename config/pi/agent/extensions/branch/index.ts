import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { forkSession, TOOL_NAME, textOf } from "./fork.ts";
import { openTerminal, requireNvim, showBuffer } from "./nvim.ts";
import { Receiver } from "./receiver.ts";
import { exitFile, inbox, listMetas, type Meta, newId, post, readJson, type Status, saveMeta, statusFile } from "./store.ts";
import { BG_BRIEF, isBrief, toolBrief, Worker } from "./worker.ts";

const run = promisify(execFile);
const POLL_MS = 1000;

interface StartParams {
	name?: string;
	task?: string;
	model?: string;
	write?: boolean;
}

export default function (pi: ExtensionAPI) {
	let current: ExtensionContext | undefined;
	let worker: Worker | undefined;
	let receiver: Receiver | undefined;
	let timer: NodeJS.Timeout | undefined;

	function startPolling() {
		timer ??= setInterval(() => {
			if (!current) return;
			try {
				worker?.takeSteers(current);
				receiver?.poll(current);
			} catch (error) {
				current.ui.notify(`branch: ${(error as Error).message}`, "error");
			}
		}, POLL_MS);
	}

	pi.on("session_start", async (_event, ctx) => {
		current = ctx;
		receiver = new Receiver(pi, ctx);
		const mine = listMetas().find((m) => m.workerFile === ctx.sessionManager.getSessionFile());
		worker = mine && (await Worker.attach(pi, mine, ctx));
		if (worker || receiver.waiting) startPolling();
	});

	pi.on("session_shutdown", () => {
		clearInterval(timer);
		timer = current = worker = receiver = undefined;
	});

	pi.on("agent_start", (_event, ctx) => {
		current = ctx;
		worker?.onAgentStart();
		receiver?.onAgentStart();
	});

	pi.on("agent_end", () => worker?.onAgentEnd());

	pi.on("agent_settled", (_event, ctx) => worker?.onAgentSettled(ctx));

	pi.on("message_end", (event) => {
		if (event.message.role === "user") worker?.onUserMessage(textOf(event.message.content));
	});

	pi.on("tool_call", (event, ctx) => {
		const reason = worker?.blockReason(event.toolName, event.input, ctx.cwd);
		if (reason) return { block: true, reason };
	});

	const related = (ctx: ExtensionContext) => {
		const file = ctx.sessionManager.getSessionFile();
		return listMetas().filter((m) => m.receiverFile === file || m.workerFile === file);
	};

	function branchNamed(ctx: ExtensionContext, name?: string): Meta {
		const metas = related(ctx).filter((m) => !name || m.name === name);
		if (metas.length !== 1) throw new Error(name ? `no branch named "${name}"` : "name a branch: there isn't exactly one");
		return metas[0];
	}

	function uniqueName(ctx: ExtensionContext, wanted: string): string {
		const base = wanted.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-|-$/g, "") || "branch";
		const taken = new Set(related(ctx).map((m) => m.name));
		let name = base;
		for (let i = 2; taken.has(name); i++) name = `${base}-${i}`;
		return name;
	}

	async function start(ctx: ExtensionContext, p: StartParams): Promise<string> {
		requireNvim();
		const parentFile = ctx.sessionManager.getSessionFile();
		const leafId = ctx.sessionManager.getLeafId();
		if (!parentFile || !leafId) throw new Error("branching needs a saved session");
		if (!p.task?.trim()) throw new Error("start needs a task");
		const name = uniqueName(ctx, p.name ?? "branch");
		const workspace = p.write ? await addWorkspace(ctx.cwd, name) : undefined;
		const cwd = workspace ?? ctx.cwd;
		const meta: Meta = {
			id: newId(), name, flow: "tool", cwd, workspace, receiverFile: parentFile, model: p.model ?? modelOf(ctx),
			workerFile: forkSession({ parentFile, leafId, cwd, forWorker: true }), createdAt: new Date().toISOString(),
		};
		saveMeta(meta);
		const cmd = piCommand(meta.workerFile, meta.model, toolBrief(p.task, workspace));
		meta.buf = (await openTerminal({ name, cmd, cwd, exitFile: exitFile(meta.id), show: false })).buf;
		saveMeta(meta);
		receiver?.add(meta);
		startPolling();
		return `Started branch "${name}" (nvim buffer ${meta.buf}, model ${meta.model}${workspace ? `, workspace ${workspace}` : ""}). Its report will arrive as a message; don't wait for it.`;
	}

	/** The running turn carries on here as a worker; the user continues in a fork that ends at their last message. */
	async function background(ctx: ExtensionContext, wanted: string): Promise<void> {
		requireNvim();
		if (worker) throw new Error("this session is already a background branch");
		if (ctx.isIdle()) throw new Error("nothing is running; ask for a branch instead");
		const workerFile = ctx.sessionManager.getSessionFile();
		const lastUser = ctx.sessionManager.getBranch().findLast((e) => e.type === "message" && e.message.role === "user");
		if (!workerFile || !lastUser) throw new Error("nothing to fork yet");
		const name = uniqueName(ctx, wanted || "bg");
		const receiverFile = forkSession({
			parentFile: workerFile, leafId: lastUser.id, cwd: ctx.cwd, forWorker: false,
			marker: `This request is running in background branch \`${name}\`; its result will be posted here. It edits this same working copy, so leave the files it's working on alone until it reports.`,
		});
		const meta: Meta = {
			id: newId(), name, flow: "bg", cwd: ctx.cwd, workerFile, receiverFile, model: modelOf(ctx), createdAt: new Date().toISOString(),
		};
		saveMeta(meta);
		meta.buf = (await openTerminal({ name, cmd: piCommand(receiverFile, meta.model), cwd: ctx.cwd, show: true })).own;
		saveMeta(meta);
		worker = await Worker.attach(pi, meta, ctx);
		pi.sendUserMessage(BG_BRIEF, { deliverAs: "steer" });
		startPolling();
	}

	function listing(ctx: ExtensionContext): string {
		const file = ctx.sessionManager.getSessionFile();
		const metas = related(ctx);
		if (metas.length === 0) return "No branches.";
		return metas
			.map((m) => {
				const role = m.workerFile === file ? "this session is its worker" : "reports here";
				return `${m.name}: ${stateOf(m)}, ${role}, buffer ${m.buf ?? "?"}, ${m.model ?? "default model"}, ${m.workspace ?? m.cwd}`;
			})
			.join("\n");
	}

	pi.registerTool({
		name: TOOL_NAME,
		label: "Branch",
		description: `Fork this conversation into a background pi session (a Neovim terminal buffer) that works on a task and reports back here.
- start: needs name and task. The branch inherits the whole conversation, so the task can be short. Optional model ("provider/id:thinking"; default: this session's model; only use a 200K-context model like claude-haiku-4-5 when this conversation is well under that). write: true gives it its own jj workspace; leave it off for read-only work.
- peek: the branch's progress so far. steer: send it a message; it lands after its current tool call finishes (a running command isn't interrupted). list: all branches of this session.
Reports arrive as messages on their own. After start, return control or keep working: never sleep or poll waiting for a report.`,
		promptSnippet: "Fork the conversation into a background pi session that reports back",
		promptGuidelines: [
			"Use the branch tool only when the user asks for background or delegated work, directly or through their instructions; a task being big isn't a reason on its own.",
			"One writer per working copy: branches that edit files need write: true.",
		],
		parameters: Type.Object({
			action: StringEnum(["start", "peek", "steer", "list"] as const),
			name: Type.Optional(Type.String({ description: "Branch name, e.g. scout-auth" })),
			task: Type.Optional(Type.String({ description: "start: what the branch should do" })),
			message: Type.Optional(Type.String({ description: "steer: the message" })),
			model: Type.Optional(Type.String({ description: "start: provider/id[:thinking]" })),
			write: Type.Optional(Type.Boolean({ description: "start: give it its own jj workspace to edit in" })),
		}),
		async execute(_id, params, _signal, _onUpdate, ctx) {
			let text: string;
			switch (params.action) {
				case "start":
					text = await start(ctx, params);
					break;
				case "peek":
					text = peek(branchNamed(ctx, params.name));
					break;
				case "steer": {
					if (!params.message?.trim()) throw new Error("steer needs a message");
					const meta = branchNamed(ctx, params.name);
					post(meta.id, "to-worker", { id: newId(), text: params.message });
					text = `Queued for "${meta.name}". peek shows when it's delivered.`;
					break;
				}
				case "list":
					text = listing(ctx);
			}
			return { content: [{ type: "text", text }], details: undefined };
		},
	});

	const command = (name: string, description: string, handler: (args: string, ctx: ExtensionContext) => Promise<void>) =>
		pi.registerCommand(name, {
			description,
			handler: (args, ctx) =>
				handler(args.trim(), ctx).catch((error: Error) => ctx.ui.notify(`/${name}: ${error.message}`, "error")),
		});

	command("bg", "Move the running turn to the background and continue in a fork of this conversation", (args, ctx) =>
		background(ctx, args),
	);
	command("fg", "Show a branch's terminal in this window (:b# to come back)", async (args, ctx) => {
		const meta = branchNamed(ctx, args || undefined);
		if (meta.buf === undefined) throw new Error(`"${meta.name}" has no terminal buffer`);
		await showBuffer(meta.buf);
	});
	command("branches", "List this session's branches", async (_args, ctx) => ctx.ui.notify(listing(ctx), "info"));
}

function stateOf(meta: Meta): string {
	if (fs.existsSync(exitFile(meta.id))) return "exited";
	return readJson<Status>(statusFile(meta.id))?.state ?? "starting";
}

type LoggedMessage = { role: string; content?: unknown; toolName?: string; isError?: boolean };
type LoggedBlock = { type: string; text?: string; name?: string; arguments?: unknown };

/** The worker's own work: everything from its brief onwards. */
function peek(meta: Meta): string {
	const messages = fs
		.readFileSync(meta.workerFile, "utf8")
		.split("\n")
		.filter(Boolean)
		.flatMap((line) => {
			const entry = JSON.parse(line) as { type: string; message?: LoggedMessage };
			return entry.type === "message" && entry.message ? [entry.message] : [];
		});
	const briefOf = (m: LoggedMessage) => m.role === "user" && isBrief(textOf(m.content));
	const items = messages.slice(Math.max(0, messages.findLastIndex(briefOf))).flatMap((m): string[] => {
		if (m.role === "user") return [briefOf(m) ? "(brief)" : `user: ${clip(textOf(m.content), 200)}`];
		if (m.role === "toolResult") return m.isError ? [`  ✗ ${m.toolName}: ${clip(textOf(m.content), 160)}`] : [];
		if (m.role !== "assistant" || !Array.isArray(m.content)) return [];
		return (m.content as LoggedBlock[]).flatMap((b) => {
			if (b.type === "text" && b.text?.trim()) return [`assistant: ${clip(b.text, 300)}`];
			if (b.type === "toolCall") return [`  → ${b.name} ${clip(JSON.stringify(b.arguments), 120)}`];
			return [];
		});
	});
	const steers = (state: string) => inbox(meta.id, "to-worker", state).length;
	const header = `${meta.name}: ${stateOf(meta)}; steers queued ${steers("json") + steers("sent")}, delivered ${steers("delivered")}`;
	return [header, ...items.slice(-20)].join("\n");
}

async function addWorkspace(cwd: string, name: string): Promise<string> {
	const root = (await run("jj", ["root"], { cwd })).stdout.trim();
	const dir = path.join(path.dirname(root), `${path.basename(root)}-${name}`);
	if (fs.existsSync(dir)) throw new Error(`${dir} already exists`);
	await run("jj", ["workspace", "add", "--name", name, "-r", "@", dir], { cwd: root });
	return dir;
}

function modelOf(ctx: ExtensionContext): string | undefined {
	if (!ctx.model) return undefined;
	return `${ctx.model.provider}/${ctx.model.id}${ctx.thinkingLevel ? `:${ctx.thinkingLevel}` : ""}`;
}

function piCommand(sessionFile: string, model: string | undefined, prompt?: string): string[] {
	return [process.execPath, process.argv[1], "--session", sessionFile, ...(model ? ["--model", model] : []), ...(prompt ? [prompt] : [])];
}

function clip(text: string, max: number): string {
	const flat = text.replace(/\s+/g, " ").trim();
	return flat.length > max ? `${flat.slice(0, max)}…` : flat;
}
