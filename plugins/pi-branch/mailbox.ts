import fs from "node:fs";
import path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { textOf } from "./fork.ts";
import { preview } from "./receiver.ts";
import { type Message, messagesIn, newId, postTo, readJson, ROOT, sessionDir, writeJson } from "./store.ts";

export const MESSAGE_TYPE = "session-message";

/** A running pi session that can be messaged. */
export interface Presence {
	id: string;
	name: string;
	cwd: string;
	pid: number;
	/** Its session file, where a truncated reply can be read in full. */
	file?: string;
}

/** A request asks for work; its recipient answers with an ack on delivery and a reply once its run settles. */
type Kind = "request" | "ack" | "reply";

type Letter = Message & { from: Presence; kind?: Kind };

type Delivery = { content: (letter: Letter) => string; options: (idle: boolean) => { triggerTurn: boolean } | { deliverAs: "steer" } };

const wake = (idle: boolean) => (idle ? { triggerTurn: true } : { deliverAs: "steer" as const });

const sender = ({ name, id, cwd }: Presence) => `session **${name}** (id ${shortId(id)}, cwd ${cwd})`;

const QUOTE_CHARS = 1000;

const quote = (text: string) => (text.length > QUOTE_CHARS ? `${text.slice(0, QUOTE_CHARS)}…` : text);

const DELIVERY: Record<Kind, Delivery> = {
	request: {
		content: ({ from, text }) =>
			`Message from ${sender(from)}, sent at the user's request:\n\n${text}\n\nAct on it as you would on a request from the user. Your final answer goes back to that session on its own; don't reply with \`branch send\`.`,
		options: wake,
	},
	// Informational: appended without starting a turn, or after the current one ends.
	ack: {
		content: ({ from, text }) => `The ${sender(from)} received your message and is working on it; its answer will arrive here:\n\n${quote(text)}`,
		options: () => ({ triggerTurn: false }),
	},
	reply: {
		content: ({ from, text }) => `The ${sender(from)} answered your message:\n\n${preview(text)}${from.file ? `\n\nFull transcript: ${from.file}` : ""}`,
		options: wake,
	},
};

const presenceFile = (id: string) => path.join(sessionDir(id), "presence.json");
const inboxDir = (id: string) => path.join(sessionDir(id), "inbox");

export const shortId = (id: string) => id.slice(-8);

export const register = (self: Presence) => writeJson(presenceFile(self.id), self);

/** Keeps a non-empty inbox: its messages are delivered when the session runs again. */
export function unregister(id: string): void {
	fs.rmSync(presenceFile(id), { force: true });
	if (messagesIn(inboxDir(id)).length === 0) fs.rmSync(sessionDir(id), { recursive: true, force: true });
}

export function liveSessions(): Presence[] {
	const dir = path.join(ROOT, "sessions");
	if (!fs.existsSync(dir)) return [];
	return fs
		.readdirSync(dir)
		.map((id) => readJson<Presence>(presenceFile(id)))
		.filter((p): p is Presence => p !== undefined && alive(p.pid));
}

export function findSession(target: string, sessions: Presence[]): Presence {
	const matches = sessions.filter((s) => s.name === target || s.id === target || shortId(s.id) === target);
	if (matches.length === 0) throw new Error(`no live session "${target}"`);
	if (matches.length > 1) throw new Error(`more than one session is called "${target}"; use its id`);
	return matches[0];
}

/** Returns the message's id. */
export function send(from: Presence, to: Presence, text: string, kind: Kind = "request"): string {
	const letter: Letter = { id: newId(), text, from, kind };
	postTo(inboxDir(to.id), letter);
	return letter.id;
}

/** This session's inbox: posts each message once, acknowledges requests and sends back the answer to them. */
export class Mailbox {
	private readonly delivered = new Set<string>();
	/** Senders still owed an answer, with the answer that was newest when their request arrived. */
	private pending: { from: Presence; after?: string }[] = [];

	constructor(
		private readonly pi: Pick<ExtensionAPI, "sendMessage">,
		ctx: ExtensionContext,
		private readonly self: Presence,
		private readonly tellOwner?: (text: string) => void,
	) {
		for (const entry of ctx.sessionManager.getBranch()) {
			if (entry.type !== "custom_message" || entry.customType !== MESSAGE_TYPE) continue;
			const messageId = (entry.details as { messageId?: string } | undefined)?.messageId;
			if (messageId) this.delivered.add(messageId);
		}
	}

	poll(ctx: ExtensionContext) {
		for (const { file, message } of messagesIn(inboxDir(this.self.id))) {
			if (!this.delivered.has(message.id)) this.deliver(ctx, message as Letter);
			fs.unlinkSync(file);
		}
	}

	/** Answers each request delivered before this run with the run's final text, once that text is new. */
	onAgentSettled(ctx: ExtensionContext, aborted: boolean) {
		const last = lastAnswer(ctx);
		const owed = this.pending.filter((p) => aborted || (last && last.id !== p.after));
		if (owed.length === 0) return;
		const text = aborted ? "Cancelled before it finished; work may be incomplete." : textOf(last?.message.content);
		for (const { from } of owed) send(this.self, from, text, "reply");
		this.pending = this.pending.filter((p) => !owed.includes(p));
	}

	private deliver(ctx: ExtensionContext, letter: Letter) {
		const kind = letter.kind ?? "request";
		this.delivered.add(letter.id);
		const { content, options } = DELIVERY[kind];
		this.pi.sendMessage({ customType: MESSAGE_TYPE, content: content(letter), display: true, details: { messageId: letter.id, from: letter.from.id, kind } }, options(ctx.isIdle()));
		if (kind !== "request") return;

		send(this.self, letter.from, letter.text, "ack");
		this.tellOwner?.(`received a message from ${sender(letter.from)} and acknowledged it; its answer goes back to that session as well as here:\n\n${quote(letter.text)}`);
		this.pending.push({ from: letter.from, after: lastAnswer(ctx)?.id });
	}
}

export function lastAnswer(ctx: ExtensionContext) {
	const entry = ctx.sessionManager.getBranch().findLast((e) => e.type === "message" && e.message.role === "assistant");
	return entry?.type === "message" ? entry : undefined;
}

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}
