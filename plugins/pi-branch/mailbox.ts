import fs from "node:fs";
import path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type Message, messagesIn, newId, postTo, readJson, ROOT, sessionDir, writeJson } from "./store.ts";

export const MESSAGE_TYPE = "session-message";

/** A running pi session that can be messaged. */
export interface Presence {
	id: string;
	name: string;
	cwd: string;
	pid: number;
}

type Letter = Message & { from: Presence };

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
export function send(from: Presence, to: Presence, text: string): string {
	const letter: Letter = { id: newId(), text, from };
	postTo(inboxDir(to.id), letter);
	return letter.id;
}

/** This session's inbox: posts each message once, waking the agent if it's idle. */
export class Mailbox {
	private readonly delivered = new Set<string>();

	constructor(
		private readonly pi: Pick<ExtensionAPI, "sendMessage">,
		ctx: ExtensionContext,
		private readonly id: string,
	) {
		for (const entry of ctx.sessionManager.getBranch()) {
			if (entry.type !== "custom_message" || entry.customType !== MESSAGE_TYPE) continue;
			const messageId = (entry.details as { messageId?: string } | undefined)?.messageId;
			if (messageId) this.delivered.add(messageId);
		}
	}

	poll(ctx: ExtensionContext) {
		for (const { file, message } of messagesIn(inboxDir(this.id))) {
			if (!this.delivered.has(message.id)) this.deliver(ctx, message as Letter);
			fs.unlinkSync(file);
		}
	}

	private deliver(ctx: ExtensionContext, { id, text, from }: Letter) {
		this.delivered.add(id);
		const message = {
			customType: MESSAGE_TYPE,
			content: `Message from session **${from.name}** (id ${shortId(from.id)}, cwd ${from.cwd}), sent at the user's request:\n\n${text}\n\nAct on it as you would on a request from the user. Reply with \`branch send\` only if it asks for a reply.`,
			display: true,
			details: { messageId: id, from: from.id },
		};
		if (ctx.isIdle()) this.pi.sendMessage(message, { triggerTurn: true });
		else this.pi.sendMessage(message, { deliverAs: "steer" });
	}
}

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}
