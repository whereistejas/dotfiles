import { execFile } from "node:child_process";

const CACHE_TTL_MS = 5 * 60 * 1000;

export function loadToken(signal) {
	return new Promise((resolve, reject) => {
		execFile("aigw", ["token"], { signal, timeout: 10000, encoding: "utf8" }, (error, stdout) => {
			if (error || !stdout.trim()) {
				reject(new Error("Could not obtain gateway token. Run `aigw login` and retry."));
				return;
			}
			resolve(stdout.trim());
		});
	});
}

export function createTokenCache(load = loadToken, now = Date.now) {
	let cached;
	let pending;

	return async (signal) => {
		signal.throwIfAborted();
		if (cached && now() < cached.validUntil) return cached.token;

		if (!pending) {
			pending = (async () => {
				const token = await load(signal);
				signal.throwIfAborted();
				let validUntil = now() + CACHE_TTL_MS;
				try {
					const { expires } = JSON.parse(Buffer.from(token, "base64").toString("utf8"));
					if (typeof expires === "number" && Number.isFinite(expires)) {
						validUntil = Math.min(validUntil, expires * 1000 - 30000);
					}
				} catch {}
				cached = { token, validUntil };
				return token;
			})();
		}

		const request = pending;
		try {
			const token = await request;
			signal.throwIfAborted();
			return token;
		} finally {
			if (pending === request) pending = undefined;
		}
	};
}
