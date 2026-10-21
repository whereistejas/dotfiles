/**
 * jj-commit-mention extension.
 *
 * Adds autocomplete for Jujutsu (jj) bookmarks and commits, merged with pi's built-in
 * `@` file completion.
 *
 * Two forms are supported:
 *
 *   @<query>              bookmarks/commits of the repo containing the session cwd,
 *                         merged with file suggestions. Filter by bookmark name,
 *                         change id prefix, commit id prefix, or fuzzy description.
 *
 *   @<path>:<query>       bookmarks/commits of *another* repo. `<path>` is a directory
 *                         (absolute, `~`-relative, or relative to the session cwd) that
 *                         lives inside a jj repo. Selecting an item inserts
 *                         `@<path>:<change-id>`.
 *
 *   @[<path>/]bb:<query>  bookmarks only (of the repo at `<path>`, else the cwd repo).
 *   @[<path>/]ff:<query>  files only, as if `@[<path>/]<query>` had been typed.
 *
 * Cost control (repos with a lot of changes):
 *   - jj is only run for a path once the token contains `:` and the path resolves to an
 *     existing directory inside a jj repo. Plain `@foo/bar` never shells out to jj beyond
 *     a cached `jj root` probe.
 *   - `jj log` uses `-n <limit>` over a lazy revset instead of sorting the whole history.
 *   - Per-repo results are cached with a short TTL and served stale while refreshing in the
 *     background, so a slow repo only ever costs one background fetch.
 *   - Lookups never block the autocomplete popup for longer than the soft deadline; if data
 *     isn't ready a "loading" placeholder is shown and the next keystroke picks up the cache.
 *
 * Environment overrides:
 *   PI_JJ_MENTION_REVSET      revset to source commits from (default: `::`)
 *   PI_JJ_MENTION_LIMIT       max commits to load per repo (default: 300)
 *   PI_JJ_MENTION_DEADLINE_MS max ms to wait for a cold repo fetch (default: 250)
 */

import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { stat } from "node:fs/promises";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
	type AutocompleteItem,
	type AutocompleteProvider,
	type AutocompleteSuggestions,
	fuzzyFilter,
	visibleWidth,
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

type RepoData = {
	bookmarks: Bookmark[];
	commits: Commit[];
};

const FIELD = "\x1f"; // unit separator between fields in the jj template output
const MAX_SUGGESTIONS = 20;
const CACHE_TTL_MS = 5_000;
const ROOT_CACHE_TTL_MS = 30_000;
// Keeps details aligned with pi's file suggestions (32-col primary column incl. 2-col gap).
const MIN_TAG_COLUMN = 30;
const DIM = "\x1b[2m";
const UNDIM = "\x1b[22m";

/** One suggestion row: `tag` is inserted on selection unless `value` overrides it. */
type Row = {
	tag: string;
	detail: string;
	value?: string;
};

function commitLimit(): number {
	const raw = process.env.PI_JJ_MENTION_LIMIT;
	const parsed = raw ? Number.parseInt(raw, 10) : Number.NaN;
	return Number.isFinite(parsed) && parsed > 0 ? parsed : 300;
}

// `::` is evaluated lazily in reverse topological order, so `-n <limit>` stops early
// instead of walking (and date-sorting) the entire history like `latest(all(), N)` does.
function revset(): string {
	return process.env.PI_JJ_MENTION_REVSET ?? "::";
}

function deadlineMs(): number {
	const raw = process.env.PI_JJ_MENTION_DEADLINE_MS;
	const parsed = raw ? Number.parseInt(raw, 10) : Number.NaN;
	return Number.isFinite(parsed) && parsed >= 0 ? parsed : 250;
}

type JjToken = {
	/** Everything after `@`, verbatim. */
	raw: string;
	/** Path part as typed, when the token contains `:`. */
	pathText?: string;
	/** Text to filter bookmarks/commits with. */
	query: string;
	/** Set by a `bb:`/`ff:` marker; `scope` is the raw text before the marker. */
	filter?: { kind: "bookmarks" | "files"; scope: string };
};

// Matches `@<token>` at the cursor, anchored on a whitespace/start boundary
// (same boundary rule pi uses for `@` file mentions). Explicitly excludes the old
// `@jj:` format to avoid confusion.
function extractJjToken(textBeforeCursor: string): JjToken | undefined {
	const match = textBeforeCursor.match(/(?:^|\s)@(?!jj:)([^\s]*)$/);
	const raw = match?.[1];
	if (raw === undefined) {
		return undefined;
	}

	const filtered = raw.match(/^([^:]*\/)?(bb|ff):([^:]*)$/);
	if (filtered) {
		const scope = filtered[1] ?? "";
		return {
			raw,
			pathText: scope ? scope.replace(/\/+$/, "") || "/" : undefined,
			query: filtered[3] ?? "",
			filter: { kind: filtered[2] === "bb" ? "bookmarks" : "files", scope },
		};
	}

	// Change ids, commit ids and bookmark names never contain `:`, so the last `:`
	// separates the repo path from the query.
	const sep = raw.lastIndexOf(":");
	if (sep === -1) {
		return { raw, query: raw };
	}
	return { raw, pathText: raw.slice(0, sep), query: raw.slice(sep + 1) };
}

// Cheap heuristic: only probe the filesystem for tokens that actually look like a path,
// so ordinary change-id typing never hits `stat`/`jj root`.
function looksLikePath(text: string): boolean {
	return text.length > 0 && (text.includes("/") || text.startsWith("~") || text === "." || text === "..");
}

function expandPath(pathText: string, cwd: string): string {
	if (pathText === "~") {
		return homedir();
	}
	if (pathText.startsWith("~/")) {
		return resolve(homedir(), pathText.slice(2));
	}
	return isAbsolute(pathText) ? resolve(pathText) : resolve(cwd, pathText);
}

/** Tag prefix for a repo-scoped item: `@<path>:` (empty for the cwd repo). */
function tagPrefix(pathText: string | undefined): string {
	return pathText ? `@${pathText}:` : "@";
}

function bookmarkToRow(bookmark: Bookmark, pathText: string | undefined): Row {
	return {
		tag: `${tagPrefix(pathText)}${bookmark.name}`,
		detail: `bookmark → ${bookmark.changeId}`,
	};
}

function commitToRow(commit: Commit, pathText: string | undefined): Row {
	return {
		tag: `${tagPrefix(pathText)}${commit.changeId}`,
		detail: `${commit.commitId} ${commit.description || "(no description)"}`,
	};
}

// pi's SelectList clips labels to a fixed 32-col column when an item has a description,
// so tag and detail go into the label, which is only clipped at the terminal edge.
function rowsToItems(rows: Row[]): AutocompleteItem[] {
	const column = rows.reduce((widest, row) => Math.max(widest, visibleWidth(row.tag)), MIN_TAG_COLUMN);
	return rows.map((row) => {
		const padding = " ".repeat(column - visibleWidth(row.tag) + 2);
		return {
			value: row.value ?? row.tag,
			label: `${row.tag}${padding}${DIM}${row.detail}${UNDIM}`,
		};
	});
}

function filterBookmarks(
	bookmarks: Bookmark[],
	query: string,
	pathText: string | undefined,
): Row[] {
	const q = query.trim();
	if (!q) {
		return bookmarks.map((b) => bookmarkToRow(b, pathText));
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

	return matched.map((b) => bookmarkToRow(b, pathText));
}

function filterCommits(commits: Commit[], query: string, pathText: string | undefined): Row[] {
	const q = query.trim();
	if (!q) {
		return commits.slice(0, MAX_SUGGESTIONS).map((c) => commitToRow(c, pathText));
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

	return ranked.slice(0, MAX_SUGGESTIONS).map((c) => commitToRow(c, pathText));
}

async function fetchBookmarks(pi: ExtensionAPI, cwd: string): Promise<Bookmark[]> {
	// `jj bookmark list` templates run in a RefName context: the target commit is reached
	// through `normal_target` (absent for conflicted bookmarks).
	const template = `name ++ "\\x1f" ++ if(normal_target, normal_target.change_id().short(8)) ++ "\\n"`;

	let result: Awaited<ReturnType<ExtensionAPI["exec"]>>;
	try {
		result = await pi.exec("jj", ["bookmark", "list", "--all-remotes", "-T", template], {
			cwd,
			timeout: 5_000,
		});
	} catch {
		return [];
	}

	if (result.code !== 0) {
		return [];
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

async function fetchCommits(pi: ExtensionAPI, cwd: string): Promise<Commit[]> {
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
				"-n",
				String(commitLimit()),
				"-r",
				revset(),
				"-T",
				template,
			],
			{ cwd, timeout: 15_000 },
		);
	} catch {
		return [];
	}

	if (result.code !== 0) {
		return [];
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

/** Resolves directories to their jj repo root, caching hits and misses. */
function createRootResolver(pi: ExtensionAPI) {
	const cache = new Map<string, { root: string | undefined; checkedAt: number }>();
	const inflight = new Map<string, Promise<string | undefined>>();

	const probe = async (dir: string): Promise<string | undefined> => {
		try {
			const info = await stat(dir);
			if (!info.isDirectory()) {
				return undefined;
			}
		} catch {
			return undefined;
		}

		const result = await pi
			.exec("jj", ["root", "--ignore-working-copy"], { cwd: dir, timeout: 5_000 })
			.catch(() => undefined);
		if (!result || result.code !== 0) {
			return undefined;
		}
		const root = result.stdout.trim();
		return root || undefined;
	};

	return async function resolveRoot(dir: string): Promise<string | undefined> {
		const cached = cache.get(dir);
		if (cached && Date.now() - cached.checkedAt < ROOT_CACHE_TTL_MS) {
			return cached.root;
		}

		let pending = inflight.get(dir);
		if (!pending) {
			pending = probe(dir)
				.then((root) => {
					cache.set(dir, { root, checkedAt: Date.now() });
					inflight.delete(dir);
					return root;
				})
				.catch(() => {
					inflight.delete(dir);
					return undefined;
				});
			inflight.set(dir, pending);
		}
		return pending;
	};
}

/** Per-repo bookmark/commit cache with stale-while-revalidate semantics. */
function createRepoStore(pi: ExtensionAPI) {
	const cache = new Map<string, { data: RepoData; fetchedAt: number }>();
	const inflight = new Map<string, Promise<RepoData | undefined>>();

	const refresh = (root: string): Promise<RepoData | undefined> => {
		let pending = inflight.get(root);
		if (pending) {
			return pending;
		}

		pending = Promise.all([fetchBookmarks(pi, root), fetchCommits(pi, root)])
			.then(([bookmarks, commits]) => {
				const data: RepoData = { bookmarks, commits };
				cache.set(root, { data, fetchedAt: Date.now() });
				inflight.delete(root);
				return data;
			})
			.catch(() => {
				inflight.delete(root);
				return cache.get(root)?.data;
			});
		inflight.set(root, pending);
		return pending;
	};

	return {
		/** Returns cached data (refreshing in the background when stale), else undefined. */
		peek(root: string): RepoData | undefined {
			const entry = cache.get(root);
			if (!entry) {
				return undefined;
			}
			if (Date.now() - entry.fetchedAt >= CACHE_TTL_MS) {
				void refresh(root);
			}
			return entry.data;
		},
		/** Waits at most `timeout` ms for a cold repo, leaving the fetch running afterwards. */
		async get(root: string, timeout: number): Promise<RepoData | undefined> {
			const cached = this.peek(root);
			if (cached) {
				return cached;
			}

			const pending = refresh(root);
			if (timeout <= 0) {
				return undefined;
			}
			return await Promise.race([
				pending,
				new Promise<undefined>((res) => {
					const timer = setTimeout(() => res(undefined), timeout);
					timer.unref?.();
				}),
			]);
		},
		warm(root: string): void {
			void refresh(root);
		},
	};
}

function loadingRow(token: JjToken, root: string): Row {
	return {
		tag: `@${token.raw}`,
		detail: `loading changes from ${root}… keep typing or press Tab`,
	};
}

function createCommitProvider(
	current: AutocompleteProvider,
	cwd: string,
	resolveRoot: (dir: string) => Promise<string | undefined>,
	repos: ReturnType<typeof createRepoStore>,
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

			const delegate = () => current.getSuggestions(lines, cursorLine, cursorCol, options);
			const finish = (items: AutocompleteItem[]): AutocompleteSuggestions | null =>
				items.length > 0 ? { items, prefix: `@${token.raw}` } : null;

			// `@[<path>/]ff:<query>` — files only: ask the built-in provider about the token
			// with the marker removed, then replace the whole original token on selection.
			if (token.filter?.kind === "files") {
				const stripped = `${token.filter.scope}${token.query}`;
				const start = cursorCol - token.raw.length;
				const rewritten = [...lines];
				rewritten[cursorLine] = currentLine.slice(0, start) + stripped + currentLine.slice(cursorCol);
				const files = await current.getSuggestions(rewritten, cursorLine, start + stripped.length, options);
				return finish(files?.items ?? []);
			}

			// `@[<path>/]bb:<query>` — bookmarks only, of `<path>`'s repo or the cwd repo.
			if (token.filter?.kind === "bookmarks") {
				const root = await resolveRoot(token.pathText !== undefined ? expandPath(token.pathText, cwd) : cwd);
				if (!root || options.signal.aborted) {
					return null;
				}
				const data = await repos.get(root, deadlineMs());
				if (options.signal.aborted) {
					return null;
				}
				if (!data) {
					return finish(rowsToItems([loadingRow(token, root)]));
				}
				return finish(rowsToItems(filterBookmarks(data.bookmarks, token.query, token.pathText)));
			}

			// `@<path>:<query>` — repo-scoped. jj only runs once the path is a real
			// directory inside a jj repo.
			if (token.pathText !== undefined) {
				const dir = expandPath(token.pathText, cwd);
				const root = await resolveRoot(dir);
				if (options.signal.aborted) {
					return delegate();
				}
				if (!root) {
					return delegate();
				}

				// `@:<query>` (empty path) means "this repo", so emit plain `@<change-id>` tags.
				const pathText = token.pathText || undefined;
				const data = await repos.get(root, deadlineMs());
				if (options.signal.aborted) {
					return delegate();
				}
				if (!data) {
					return finish(rowsToItems([loadingRow(token, root)]));
				}

				return finish(
					rowsToItems([
						...filterBookmarks(data.bookmarks, token.query, pathText),
						...filterCommits(data.commits, token.query, pathText),
					]),
				);
			}

			// `@<query>` — bookmarks/commits of the cwd repo merged with file suggestions.
			const cwdRoot = await resolveRoot(cwd);
			const data = cwdRoot ? repos.peek(cwdRoot) : undefined;
			const bookmarkRows = data ? filterBookmarks(data.bookmarks, token.query, undefined) : [];
			const commitRows = data ? filterCommits(data.commits, token.query, undefined) : [];

			// Offer `@<dir>:` as a hint when the typed path is another jj repo.
			const repoHint: Row[] = [];
			if (looksLikePath(token.query)) {
				const otherRoot = await resolveRoot(expandPath(token.query, cwd));
				if (otherRoot && otherRoot !== cwdRoot) {
					repoHint.push({
						tag: `@${token.query}:`,
						detail: `jj repo ${otherRoot} → type a change id or bookmark`,
					});
					repos.warm(otherRoot);
				}
			}

			const fileSuggestions = await delegate();
			if (options.signal.aborted) {
				return fileSuggestions;
			}
			return finish([
				...rowsToItems([...repoHint, ...bookmarkRows, ...commitRows]),
				...(fileSuggestions?.items ?? []),
			]);
		},

		applyCompletion(lines, cursorLine, cursorCol, item, prefix) {
			// `@<path>:` hints must not get a trailing space; the user keeps typing the id.
			if (item.value.endsWith(":")) {
				const line = lines[cursorLine] ?? "";
				const before = line.slice(0, cursorCol - prefix.length);
				const after = line.slice(cursorCol);
				const nextLines = [...lines];
				nextLines[cursorLine] = `${before}${item.value}${after}`;
				return { lines: nextLines, cursorLine, cursorCol: before.length + item.value.length };
			}
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

		// Only activate when jj is installed; otherwise every path probe would shell out in vain.
		const version = await pi.exec("jj", ["--version"], { timeout: 5_000 }).catch(() => undefined);
		if (!version || version.code !== 0) {
			return;
		}

		const resolveRoot = createRootResolver(pi);
		const repos = createRepoStore(pi);

		// Warm the cwd repo so the first `@` is instant. Other repos are fetched on demand.
		const cwdRoot = await resolveRoot(ctx.cwd);
		if (cwdRoot) {
			repos.warm(cwdRoot);
		}

		ctx.ui.addAutocompleteProvider((current) =>
			createCommitProvider(current, ctx.cwd, resolveRoot, repos),
		);
	});
}
