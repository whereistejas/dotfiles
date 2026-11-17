import { relative } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

export type LspSymbol = {
	name: string;
	kind: string;
	container?: string;
	file: string;
	line?: number;
	col?: number;
};

export type SymbolRequest = {
	id: string;
	cwd: string;
	query: string;
};

type SymbolReply = { done: boolean; symbols?: unknown };

/** Calls a function of `nvim.lua` in the user's Neovim; undefined when that fails. */
export type NvimCall = (fn: string, args: object, signal: AbortSignal) => Promise<SymbolReply | undefined>;

export type SymbolLookup = (query: string, signal: AbortSignal) => Promise<LspSymbol[] | undefined>;

const POLL_MS = 30;
const QUERY_TIMEOUT_MS = 3_000;

/** The query of a `@@<query>` token ending at the cursor. */
export function extractSymbolQuery(textBeforeCursor: string): string | undefined {
	return textBeforeCursor.match(/(?:^|\s)@@(\S*)$/)?.[1];
}

export function symbolRow(symbol: LspSymbol, cwd: string): { tag: string; detail: string; value: string } {
	const file = relative(cwd, symbol.file);
	const name = symbol.container ? `${symbol.container}.${symbol.name}` : symbol.name;
	const line = symbol.line === undefined ? file : `${file}:${symbol.line}`;
	const column = symbol.col === undefined ? line : `${line}:${symbol.col}`;
	return {
		tag: name,
		detail: `${symbol.kind.toLowerCase()} ${line}`,
		value: `${column} (${name})`,
	};
}

// Neovim answers `--remote-expr` synchronously, so the LSP request is started by the
// first call and collected by later ones instead of blocking the editor while it runs.
export async function querySymbols(call: NvimCall, request: SymbolRequest, signal: AbortSignal): Promise<LspSymbol[] | undefined> {
	const deadline = Date.now() + QUERY_TIMEOUT_MS;
	while (!signal.aborted && Date.now() < deadline) {
		const reply = await call("symbols", request, signal).catch(() => undefined);
		if (!reply) {
			return undefined;
		}
		if (reply.done) {
			return Array.isArray(reply.symbols) ? unique(reply.symbols) : [];
		}
		await sleep(POLL_MS, undefined, { signal }).catch(() => undefined);
	}
	return undefined;
}

function unique(symbols: LspSymbol[]): LspSymbol[] {
	const seen = new Set<string>();
	return symbols.filter((symbol) => {
		const key = `${symbol.file}:${symbol.line}:${symbol.col}:${symbol.name}`;
		if (seen.has(key)) {
			return false;
		}
		seen.add(key);
		return true;
	});
}

/** Caches lookups per query for `ttlMs`; failed lookups are retried on the next call. */
export function createSymbolCache(lookup: SymbolLookup, ttlMs: number): SymbolLookup {
	const cache = new Map<string, { symbols: LspSymbol[]; fetchedAt: number }>();
	return async (query, signal) => {
		const hit = cache.get(query);
		if (hit && Date.now() - hit.fetchedAt < ttlMs) {
			return hit.symbols;
		}

		const symbols = await lookup(query, signal);
		if (symbols) {
			cache.set(query, { symbols, fetchedAt: Date.now() });
		}
		return symbols;
	};
}
