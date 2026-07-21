/**
 * jj-commit-mention extension.
 *
 * Adds autocomplete for Jujutsu (jj) bookmarks and commits, merged with pi's built-in
 * `@` file completion. Type `@` in the editor to see bookmarks, commits, and files,
 * then filter by:
 *   - bookmark name
 *   - change id prefix
 *   - commit id prefix
 *   - fuzzy match on the commit description
 *
 * Selecting a bookmark or commit inserts an `@<bookmark-name>` or `@<change-id>` tag,
 * mirroring how files are tagged with `@<path>`.
 *
 * Bookmarks and commits are loaded once per session via `jj bookmark list` and `jj log`,
 * cached with a short TTL, so typing stays fast and the list refreshes in the background.
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

type Bookmark = {
	name: string;
	changeId: string;
};

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

// Matches `@<query>` at the cursor, anchored on a whitespace/start boundary
// (same boundary rule pi uses for `@` file mentions). Returns the query, which
// may be an empty string right after `@`. Explicitly excludes the old `@jj:`
// format to avoid confusion.
function extractJjToken(textBeforeCursor: string): string | undefined {
	const match = textBeforeCursor.match(/(?:^|\s)@(?!jj:)([^\s]*)$/);
	return match?.[1];
}

function bookmarkToItem(bookmark: Bookmark): AutocompleteItem {
	return {
		value: `@${bookmark.name}`,
		label: `@${bookmark.name}`,
		description: `bookmark → ${bookmark.changeId}`,
	};
}

function commitToItem(commit: Commit): AutocompleteItem {
	return {
		value: `@${commit.changeId}`,
		label: `@${commit.changeId}`,
		description: `${commit.commitId} ${commit.description || "(no description)"}`,
	};
}

function filterBookmarks(bookmarks: Bookmark[], query: string): AutocompleteItem[] {
	const q = query.trim();
	if (!q) {
		return bookmarks.map(bookmarkToItem);
	}

	const lower = q.toLowerCase();
	const matched: Bookmark[] = [];

	// Exact prefix matches on bookmark name
	for (const bookmark of bookmarks) {
		if (bookmark.name.toLowerCase().startsWith(lower)) {
			matched.push(bookmark);
		}
	}

	// Then fuzzy match on name
	if (matched.length === 0) {
		const fuzzy = fuzzyFilter(bookmarks, q, (b) => b.name);
		matched.push(...fuzzy);
	}

	return matched.map(bookmarkToItem);
}

function filterCommits(commits: Commit[], query: string): AutocompleteItem[] {
	const q = query.trim();
	if (!q) {
		return commits.slice(0, MAX_SUGGESTIONS).map(commitToItem);
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

	return ranked.slice(0, MAX_SUGGESTIONS).map(commitToItem);
}

async function fetchBookmarks(pi: ExtensionAPI, cwd: string): Promise<Bookmark[] | undefined> {
	const template = `name ++ "\\x1f" ++ change_id.short(8) ++ "\\n"`;

	let result: Awaited<ReturnType<ExtensionAPI["exec"]>>;
	try {
		result = await pi.exec(
			"jj",
			["bookmark", "list", "--all-remotes", "-T", template],
			{ cwd, timeout: 3_000 },
		);
	} catch {
		return undefined;
	}

	if (result.code !== 0) {
		return undefined;
	}

	const bookmarks: Bookmark[] = [];
	const seen = new Set<string>();
	for (const line of result.stdout.split("\n")) {
		if (!line) {
			continue;
		}
		const [name, changeId] = line.split(FIELD);
		if (!name || !changeId) {
			continue;
		}
		// Deduplicate by name (local and remote branches may share names)
		if (seen.has(name)) {
			continue;
		}
		seen.add(name);
		bookmarks.push({ name, changeId });
	}
	return bookmarks;
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
	getBookmarks: () => Promise<Bookmark[] | undefined>,
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

			const [bookmarks, commits] = await Promise.all([getBookmarks(), getCommits()]);
			if (options.signal.aborted) {
				return current.getSuggestions(lines, cursorLine, cursorCol, options);
			}

			// Merge bookmark, commit, and file suggestions (in that order)
			const bookmarkItems = (bookmarks && bookmarks.length > 0) ? filterBookmarks(bookmarks, token) : [];
			const commitItems = (commits && commits.length > 0) ? filterCommits(commits, token) : [];
			const fileSuggestions = await current.getSuggestions(lines, cursorLine, cursorCol, options);
			const fileItems = fileSuggestions?.items ?? [];

			const mergedItems = [...bookmarkItems, ...commitItems, ...fileItems];
			if (mergedItems.length === 0) {
				return null;
			}

			return { items: mergedItems, prefix: `@${token}` };
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

		let bookmarkCache: { bookmarks: Bookmark[]; fetchedAt: number } | undefined;
		let bookmarkInflight: Promise<Bookmark[] | undefined> | undefined;

		let commitCache: { commits: Commit[]; fetchedAt: number } | undefined;
		let commitInflight: Promise<Commit[] | undefined> | undefined;

		const getBookmarks = async (): Promise<Bookmark[] | undefined> => {
			const fresh = bookmarkCache && Date.now() - bookmarkCache.fetchedAt < CACHE_TTL_MS;
			if (fresh) {
				return bookmarkCache!.bookmarks;
			}

			bookmarkInflight ||= fetchBookmarks(pi, ctx.cwd)
				.then((bookmarks) => {
					if (bookmarks) {
						bookmarkCache = { bookmarks, fetchedAt: Date.now() };
					}
					bookmarkInflight = undefined;
					return bookmarkCache?.bookmarks;
				})
				.catch(() => {
					bookmarkInflight = undefined;
					return bookmarkCache?.bookmarks;
				});

			// Serve stale cache immediately while refreshing in the background.
			return bookmarkCache ? bookmarkCache.bookmarks : bookmarkInflight;
		};

		const getCommits = async (): Promise<Commit[] | undefined> => {
			const fresh = commitCache && Date.now() - commitCache.fetchedAt < CACHE_TTL_MS;
			if (fresh) {
				return commitCache!.commits;
			}

			commitInflight ||= fetchCommits(pi, ctx.cwd)
				.then((commits) => {
					if (commits) {
						commitCache = { commits, fetchedAt: Date.now() };
					}
					commitInflight = undefined;
					return commitCache?.commits;
				})
				.catch(() => {
					commitInflight = undefined;
					return commitCache?.commits;
				});

			// Serve stale cache immediately while refreshing in the background.
			return commitCache ? commitCache.commits : commitInflight;
		};

		// Warm both caches so the first `@` is instant.
		void getBookmarks();
		void getCommits();
		ctx.ui.addAutocompleteProvider((current) => createCommitProvider(current, getBookmarks, getCommits));
	});
}
