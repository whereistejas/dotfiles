/**
 * Window-title extension.
 *
 * Sets the terminal (Ghostty) window title to a short, Haiku-generated
 * summary of what the current session is working on. Shows a braille
 * spinner while the agent is running, then refreshes the summary when
 * the turn finishes. The summary is saved in the session, so a resumed
 * session gets its title back straight away.
 *
 * Title format:  "<spinner> π — <summary> — <cwd>"
 *
 * Override the model with PI_TITLE_MODEL="provider/model-id" if you don't
 * have an Anthropic API key (e.g. routing Haiku through Bedrock).
 */

import { complete, getModel } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import path from "node:path";

const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const SPINNER_INTERVAL_MS = 80;
const MAX_SUMMARY_CHARS = 48;
const SUMMARY_ENTRY = "window-title";
// pi paints its default title after session_start handlers finish.
const RESTORE_REPAINT_MS = 1000;

type ContentBlock = { type?: string; text?: string };
type SessionEntry = {
	type: string;
	customType?: string;
	data?: { summary?: unknown };
	message?: { role?: string; content?: unknown };
};

function extractText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.filter((p): p is ContentBlock => !!p && typeof p === "object")
		.filter((b) => b.type === "text" && typeof b.text === "string")
		.map((b) => b.text as string)
		.join("\n");
}

function buildConversationText(entries: SessionEntry[]): string {
	const sections: string[] = [];
	for (const entry of entries) {
		if (entry.type !== "message" || !entry.message?.role) continue;
		const role = entry.message.role;
		if (role !== "user" && role !== "assistant") continue;
		const text = extractText(entry.message.content).trim();
		if (text) sections.push(`${role === "user" ? "User" : "Assistant"}: ${text}`);
	}
	// Only the tail matters for "what are we doing right now".
	return sections.slice(-12).join("\n\n");
}

function savedSummary(entries: SessionEntry[]): string {
	for (let i = entries.length - 1; i >= 0; i--) {
		const entry = entries[i];
		if (entry.type === "custom" && entry.customType === SUMMARY_ENTRY && typeof entry.data?.summary === "string") {
			return entry.data.summary;
		}
	}
	return "";
}

function resolveModel() {
	const override = process.env.PI_TITLE_MODEL;
	if (override) {
		const [provider, ...rest] = override.split("/");
		// biome-ignore lint/suspicious/noExplicitAny: provider/model are user-supplied strings
		return getModel(provider as any, rest.join("/") as any);
	}
	// biome-ignore lint/suspicious/noExplicitAny: keep this resilient across model-table renames
	return getModel("anthropic" as any, "claude-haiku-4-5" as any);
}

export default function (pi: ExtensionAPI) {
	let timer: ReturnType<typeof setInterval> | null = null;
	let frameIndex = 0;
	let summary = "";
	let summarizing = false;

	const cwd = () => path.basename(process.cwd());

	function baseLabel(): string {
		const session = pi.getSessionName();
		const parts = ["π"];
		if (summary) parts.push(summary);
		else if (session) parts.push(session);
		parts.push(cwd());
		return parts.join(" — ");
	}

	function paint(ctx: ExtensionContext, spinner?: string) {
		ctx.ui.setTitle(spinner ? `${spinner} ${baseLabel()}` : baseLabel());
	}

	function startSpinner(ctx: ExtensionContext) {
		stopSpinner();
		timer = setInterval(() => {
			paint(ctx, SPINNER_FRAMES[frameIndex % SPINNER_FRAMES.length]);
			frameIndex++;
		}, SPINNER_INTERVAL_MS);
	}

	function stopSpinner() {
		if (timer) {
			clearInterval(timer);
			timer = null;
		}
		frameIndex = 0;
	}

	async function refreshSummary(ctx: ExtensionContext) {
		if (summarizing) return;
		const conversation = buildConversationText(ctx.sessionManager.getBranch() as SessionEntry[]);
		if (!conversation.trim()) return;

		const model = resolveModel();
		if (!model) return;
		const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
		if (!auth?.ok || !auth.apiKey) return;

		summarizing = true;
		try {
			const response = await complete(
				model,
				{
					messages: [
						{
							role: "user" as const,
							content: [
								{
									type: "text" as const,
									text: [
										"In 3–6 words, name the task being worked on in this conversation.",
										"Reply with the label only — no quotes, no punctuation, no preamble.",
										"",
										"<conversation>",
										conversation,
										"</conversation>",
									].join("\n"),
								},
							],
							timestamp: Date.now(),
						},
					],
				},
				{ apiKey: auth.apiKey, headers: auth.headers, maxTokens: 32 },
			);

			const label = response.content
				.filter((c): c is { type: "text"; text: string } => c.type === "text")
				.map((c) => c.text)
				.join(" ")
				.replace(/\s+/g, " ")
				.replace(/^["'\s]+|["'.\s]+$/g, "")
				.trim();

			if (label) {
				const next = label.length > MAX_SUMMARY_CHARS ? `${label.slice(0, MAX_SUMMARY_CHARS - 1)}…` : label;
				if (next !== summary) pi.appendEntry(SUMMARY_ENTRY, { summary: next });
				summary = next;
				paint(ctx);
			}
		} catch {
			// Title is cosmetic — never surface summarizer failures.
		} finally {
			summarizing = false;
		}
	}

	pi.on("session_start", async (_event, ctx) => {
		summary = savedSummary(ctx.sessionManager.getBranch() as SessionEntry[]);
		paint(ctx);
		if (!summary) return;
		setTimeout(() => {
			if (!timer) paint(ctx);
		}, RESTORE_REPAINT_MS);
	});

	pi.on("agent_start", async (_event, ctx) => startSpinner(ctx));

	pi.on("agent_end", async (_event, ctx) => {
		stopSpinner();
		paint(ctx);
		await refreshSummary(ctx);
	});

	pi.on("session_shutdown", async (_event, ctx) => {
		stopSpinner();
		ctx.ui.setTitle(cwd());
	});
}
