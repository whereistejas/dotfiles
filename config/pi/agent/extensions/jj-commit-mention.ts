/**
 * jj-commit-mention extension.
 *
 * Adds `@jj:` autocomplete for Jujutsu (jj) commits, layered on top of pi's
 * built-in `@` file completion. Type `@jj:` in the editor to switch from file
 * completion to commit completion, then filter by:
 *   - change id prefix
 *   - commit id prefix
 *   - fuzzy match on the commit description
 *
 * Selecting a commit inserts an `@jj:<change-id>` tag, mirroring how files are
 * tagged with `@<path>`.
 *
 * Commits are loaded once per session via `jj log` and cached with a short TTL,
 * so typing stays fast and the list refreshes in the background as you work.
 *
 * Environment overrides:
 *   PI_JJ_MENTION_REVSET  revset to source commits from (default: latest(all(), N))
 *   PI_JJ_MENTION_LIMIT   max commits to load when no revset override (default: 300)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
	type AutocompleteItem,
	type AutocompleteProvider,
	type AutocompleteSuggestions,
	fuzzyFilter,
} from "@earendil-works/pi-tui";

type Commit = {
	changeId: string;
	commitId: string;
	description: string;
};

const FIELD = "\x1f"; // unit separator between fields in the jj template output
const MAX_SUGGESTIONS = 20;
const CACHE_TTL_MS = 5_000;

function commitLimit(): number {
	const raw = process.env.PI_JJ_MENTION_LIMIT;
	const parsed = raw ? Number.parseInt(raw, 10) : Number.NaN;
	return Number.isFinite(parsed) && parsed > 0 ? parsed : 300;
}

function revset(): string {
	return process.env.PI_JJ_MENTION_REVSET ?? `latest(all(), ${commitLimit()})`;
}

// Matches `@jj:<query>` at the cursor, anchored on a whitespace/start boundary
// (same boundary rule pi uses for `@` file mentions). Returns the query, which
// may be an empty string right after `@jj:`.
function extractJjToken(textBeforeCursor: string): string | undefined {
	const match = textBeforeCursor.match(/(?:^|\s)@jj:([^\s]*)$/);
	return match?.[1];
}

function toItem(commit: Commit): AutocompleteItem {
	return {
		value: `@jj:${commit.changeId}`,
		label: `@jj:${commit.changeId}`,
		description: `${commit.commitId} ${commit.description || "(no description)"}`,
	};
}

function filterCommits(commits: Commit[], query: string): AutocompleteItem[] {
	const q = query.trim();
	if (!q) {
		return commits.slice(0, MAX_SUGGESTIONS).map(toItem);
	}

	const lower = q.toLowerCase();
	const seen = new Set<string>();
	const ranked: Commit[] = [];

	// Exact id-prefix matches (change id or commit id) come first.
	for (const commit of commits) {
		if (commit.changeId.toLowerCase().startsWith(lower) || commit.commitId.toLowerCase().startsWith(lower)) {
			if (!seen.has(commit.changeId)) {
				seen.add(commit.changeId);
				ranked.push(commit);
			}
		}
	}

	// Then fuzzy matches across id + description.
	const fuzzy = fuzzyFilter(commits, q, (c) => `${c.changeId} ${c.commitId} ${c.description}`);
	for (const commit of fuzzy) {
		if (!seen.has(commit.changeId)) {
			seen.add(commit.changeId);
			ranked.push(commit);
		}
	}

	return ranked.slice(0, MAX_SUGGESTIONS).map(toItem);
}

async function fetchCommits(pi: ExtensionAPI, cwd: string): Promise<Commit[] | undefined> {
	const template =
		`change_id.short(8) ++ "\\x1f" ++ commit_id.short(8) ++ "\\x1f" ++ ` +
		`description.first_line() ++ "\\n"`;

	let result: Awaited<ReturnType<ExtensionAPI["exec"]>>;
	try {
		result = await pi.exec(
			"jj",
			[
				"log",
				"--no-graph",
				"--color",
				"never",
				"--ignore-working-copy",
				"-r",
				revset(),
				"-T",
				template,
			],
			{ cwd, timeout: 5_000 },
		);
	} catch {
		return undefined;
	}

	if (result.code !== 0) {
		return undefined;
	}

	const commits: Commit[] = [];
	for (const line of result.stdout.split("\n")) {
		if (!line) {
			continue;
		}
		const [changeId, commitId, ...rest] = line.split(FIELD);
		if (!changeId || !commitId) {
			continue;
		}
		commits.push({ changeId, commitId, description: rest.join(FIELD) });
	}
	return commits;
}

function createCommitProvider(
	current: AutocompleteProvider,
	getCommits: () => Promise<Commit[] | undefined>,
): AutocompleteProvider {
	return {
		triggerCharacters: ["@"],

		async getSuggestions(lines, cursorLine, cursorCol, options): Promise<AutocompleteSuggestions | null> {
			const currentLine = lines[cursorLine] ?? "";
			const textBeforeCursor = currentLine.slice(0, cursorCol);
			const token = extractJjToken(textBeforeCursor);
			if (token === undefined) {
				return current.getSuggestions(lines, cursorLine, cursorCol, options);
			}

			const commits = await getCommits();
			if (options.signal.aborted || !commits || commits.length === 0) {
				return current.getSuggestions(lines, cursorLine, cursorCol, options);
			}

			const items = filterCommits(commits, token);
			if (items.length === 0) {
				return current.getSuggestions(lines, cursorLine, cursorCol, options);
			}

			return { items, prefix: `@jj:${token}` };
		},

		applyCompletion(lines, cursorLine, cursorCol, item, prefix) {
			return current.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
		},

		shouldTriggerFileCompletion(lines, cursorLine, cursorCol) {
			return current.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true;
		},
	};
}

export default function (pi: ExtensionAPI): void {
	pi.on("session_start", async (_event, ctx) => {
		// Autocomplete providers only matter in the interactive TUI.
		if (ctx.mode !== "tui") {
			return;
		}

		// Only activate inside a jj repo (and only when jj is installed).
		const root = await pi
			.exec("jj", ["root", "--ignore-working-copy"], { cwd: ctx.cwd, timeout: 5_000 })
			.catch(() => undefined);
		if (!root || root.code !== 0) {
			return;
		}

		let cache: { commits: Commit[]; fetchedAt: number } | undefined;
		let inflight: Promise<Commit[] | undefined> | undefined;

		const getCommits = async (): Promise<Commit[] | undefined> => {
			const fresh = cache && Date.now() - cache.fetchedAt < CACHE_TTL_MS;
			if (fresh) {
				return cache!.commits;
			}

			inflight ||= fetchCommits(pi, ctx.cwd)
				.then((commits) => {
					if (commits) {
						cache = { commits, fetchedAt: Date.now() };
					}
					inflight = undefined;
					return cache?.commits;
				})
				.catch(() => {
					inflight = undefined;
					return cache?.commits;
				});

			// Serve stale cache immediately while refreshing in the background.
			return cache ? cache.commits : inflight;
		};

		// Warm the cache so the first `@jj:` is instant.
		void getCommits();
		ctx.ui.addAutocompleteProvider((current) => createCommitProvider(current, getCommits));
	});
}
