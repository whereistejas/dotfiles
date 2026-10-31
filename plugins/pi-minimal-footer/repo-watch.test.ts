import assert from "node:assert/strict";
import test from "node:test";
import { revisionWatchPaths } from "./repo-watch.ts";

test("jj repositories never watch Git refs rewritten by revision queries", () => {
	assert.deepEqual(revisionWatchPaths({ jjOpHeadsDir: "/repo/.jj/heads", gitDir: "/repo/.git" }), [
		{ path: "/repo/.jj/heads" },
	]);
});

test("Git repositories still watch their revision files", () => {
	assert.deepEqual(revisionWatchPaths({ gitDir: "/repo/.git" }), [
		{ path: "/repo/.git/HEAD" },
		{ path: "/repo/.git/refs/heads", recursive: true },
		{ path: "/repo/.git/packed-refs" },
	]);
});
