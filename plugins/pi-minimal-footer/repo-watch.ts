import { join } from "node:path";

export function revisionWatchPaths(info: { jjOpHeadsDir?: string; gitDir?: string }): { path: string; recursive?: boolean }[] {
	if (info.jjOpHeadsDir) return [{ path: info.jjOpHeadsDir }];
	if (!info.gitDir) return [];
	return [
		{ path: join(info.gitDir, "HEAD") },
		{ path: join(info.gitDir, "refs", "heads"), recursive: true },
		{ path: join(info.gitDir, "packed-refs") },
	];
}
