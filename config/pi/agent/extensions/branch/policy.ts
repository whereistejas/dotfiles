import os from "node:os";
import path from "node:path";

export interface PolicyContext {
	cwd: string;
	/** Directories a worker may write to. */
	writeRoots: string[];
	/** Tools that only read, besides the built-in read tools. */
	readOnlyTools: Set<string>;
}

const READ_TOOLS = new Set(["read", "grep", "find", "ls", "ffgrep", "fffind", "codemode", "tool_search"]);
const WRITE_TOOLS = new Set(["write", "edit"]);

const REMOTE_SHELLS = new Set(["ssh", "scp", "sftp", "mosh", "telnet", "ftp", "nc", "ncat", "socat", "sudo", "doas"]);
const PATH_WRITERS = new Set(["rm", "rmdir", "mv", "mkdir", "touch", "chmod", "chown", "tee", "truncate", "trash", "unlink"]);
const COPIERS = new Set(["cp", "ln", "install"]);
const WRAPPERS = new Set(["env", "command", "exec", "nohup", "time", "nice", "xargs", "builtin"]);
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "fish"]);
const GIT_READ = new Set([
	"status", "log", "diff", "show", "blame", "rev-parse", "ls-files", "ls-tree", "grep", "describe", "cat-file",
	"shortlog", "fetch", "rev-list", "merge-base", "name-rev", "reflog", "help", "version",
]);
const SKILL_CLI_READ = new Set(["read", "search", "fetch", "checkout-info", "list", "find", "info", "structure", "read-lines", "help"]);
const SKILL_CLIS = new Set(["jira-cli", "gitlab-mr", "fetch-review-comments"]);
const GH_READ = new Set(["view", "list", "status", "diff", "checks", "browse", "search"]);
const KUBECTL_READ = new Set(["get", "describe", "logs", "explain", "api-resources", "api-versions", "version", "top", "cluster-info"]);
const AWS_READ_OP = /^(describe|list|get|head|search|lookup|scan|query|batch-get|filter|validate|help|wait|select)/;

/** Returns a reason when the tool call must be blocked in a background worker. */
export function checkToolCall(
	toolName: string,
	input: Record<string, unknown>,
	ctx: PolicyContext,
): string | undefined {
	if (READ_TOOLS.has(toolName) || ctx.readOnlyTools.has(toolName)) return undefined;
	if (WRITE_TOOLS.has(toolName)) {
		const target = typeof input.path === "string" ? input.path : "";
		return insideRoots(resolvePath(target, ctx.cwd), ctx.writeRoots)
			? undefined
			: `writing ${target} is outside the jj repo, so jj can't undo it`;
	}
	if (toolName === "bash") return checkBash(String(input.command ?? ""), ctx);
	return `tool "${toolName}" isn't known to be read-only`;
}

export function checkBash(command: string, ctx: PolicyContext): string | undefined {
	let cwd = ctx.cwd;
	for (const segment of splitSegments(command)) {
		const redirect = checkRedirects(segment, cwd, ctx.writeRoots);
		if (redirect) return redirect;
		const words = unwrap(tokenize(segment));
		if (words.length === 0) continue;
		const program = path.basename(words[0]);
		const args = words.slice(1);
		if (program === "cd") {
			cwd = resolvePath(args[0] ?? os.homedir(), cwd);
			continue;
		}
		if (SHELLS.has(program)) {
			const script = args[args.indexOf("-c") + 1];
			if (args.includes("-c") && script !== undefined) {
				const inner = checkBash(script, { ...ctx, cwd });
				if (inner) return inner;
			}
			continue;
		}
		const reason = checkProgram(program, args, cwd, ctx.writeRoots);
		if (reason) return `\`${segment.trim()}\`: ${reason}`;
	}
	return undefined;
}

function checkProgram(program: string, args: string[], cwd: string, roots: string[]): string | undefined {
	if (REMOTE_SHELLS.has(program)) return `${program} reaches outside this machine or escalates privileges`;
	if (PATH_WRITERS.has(program)) {
		const outside = args.filter((a) => !a.startsWith("-")).find((a) => !insideRoots(resolvePath(a, cwd), roots));
		return outside ? `writes ${outside}, outside the jj repo` : undefined;
	}
	if (COPIERS.has(program)) {
		const dest = flagValue(args, ["-t", "--target-directory"]) ?? args.filter((a) => !a.startsWith("-")).at(-1);
		return dest && !insideRoots(resolvePath(dest, cwd), roots) ? `writes ${dest}, outside the jj repo` : undefined;
	}
	if (program === "dd") {
		const of = args.find((a) => a.startsWith("of="))?.slice(3);
		return of && !insideRoots(resolvePath(of, cwd), roots) ? `writes ${of}, outside the jj repo` : undefined;
	}
	switch (program) {
		case "rsync":
			return args.some((a) => !a.startsWith("-") && /^[^/]*:/.test(a)) ? "rsync to a remote host" : undefined;
		case "git": {
			const sub = subcommand(args, ["-C", "-c", "--git-dir", "--work-tree"]);
			if (sub === "remote" || sub === "branch" || sub === "tag" || sub === "config") {
				return args.length <= 2 || args.includes("-v") || args.includes("--list") || args.includes("-l") || args.includes("--get")
					? undefined
					: `git ${sub} changes aren't jj-recoverable; use jj`;
			}
			return sub && GIT_READ.has(sub) ? undefined : `git ${sub ?? ""} isn't a read; use jj (and never push)`;
		}
		case "jj": {
			const rest = afterOptions(args, ["-R", "--repository", "--at-op", "--at-operation", "--color", "--config", "--config-file"]);
			const [sub, sub2] = rest;
			if (sub === "git" && (sub2 === "push" || sub2 === "remote")) return `jj git ${sub2} writes to or changes a remote`;
			if (sub === "util" && sub2 === "gc") return "jj util gc can't be undone";
			if (sub === "op" && sub2 === "abandon") return "jj op abandon can't be undone";
			return undefined;
		}
		case "curl": {
			if (args.some((a) => /^(-d|--data(-raw|-binary|-urlencode)?|-F|--form|-T|--upload-file|--json)(=|$)/.test(a) || /^-d./.test(a))) {
				return "curl sends a request body";
			}
			const method = flagValue(args, ["-X", "--request"]);
			return method && !/^(GET|HEAD)$/i.test(method) ? `curl ${method} request` : undefined;
		}
		case "wget": {
			if (args.some((a) => /^--(post-data|post-file|body-data|body-file)/.test(a))) return "wget sends a request body";
			const method = flagValue(args, ["--method"]);
			return method && !/^(GET|HEAD)$/i.test(method) ? `wget ${method} request` : undefined;
		}
		case "http":
		case "https":
		case "xh": {
			const method = args.find((a) => !a.startsWith("-"));
			return method && /^(GET|HEAD)$/i.test(method) ? undefined : `${program} without an explicit GET`;
		}
		case "aws": {
			const [service, op] = afterOptions(args, ["--profile", "--region", "--output", "--query", "--endpoint-url", "--color"]);
			if (!service || service === "help") return undefined;
			if (service === "s3" && (op === "ls" || op === "presign")) return undefined;
			if (service === "sso" && (op === "login" || op === "logout")) return undefined;
			if (service === "configure" && (op === "list" || op === "get" || op === "list-profiles")) return undefined;
			return op && AWS_READ_OP.test(op) ? undefined : `aws ${service} ${op ?? ""} isn't a read`;
		}
		case "gh":
		case "glab": {
			const [noun, verb] = afterOptions(args, ["-R", "--repo"]);
			if (noun === "api") {
				const method = flagValue(args, ["-X", "--method"]);
				const hasBody = args.some((a) => /^(-f|-F|--field|--raw-field|--input)(=|$)/.test(a));
				return hasBody || (method && !/^GET$/i.test(method)) ? `${program} api write` : undefined;
			}
			if (noun === "auth" || noun === "version" || noun === "help") return undefined;
			return verb && GH_READ.has(verb) ? undefined : `${program} ${noun ?? ""} ${verb ?? ""} isn't a read`;
		}
		case "kubectl": {
			const [sub, sub2] = afterOptions(args, ["-n", "--namespace", "--context", "-o", "--output", "--kubeconfig"]);
			if (sub === "config") return sub2 === "view" || sub2?.startsWith("get-") || sub2 === "current-context" ? undefined : "kubectl config change";
			if (sub === "auth" && sub2 === "can-i") return undefined;
			return sub && KUBECTL_READ.has(sub) ? undefined : `kubectl ${sub ?? ""} isn't a read`;
		}
		case "cargo": {
			if (args[0] === "install") return "cargo install writes outside the repo";
			const manifest = flagValue(args, ["--manifest-path"]) ?? "";
			const dash = args.indexOf("--");
			if (args[0] === "run" && manifest.includes("/skills/") && dash >= 0) {
				const sub = args[dash + 1];
				return sub && SKILL_CLI_READ.has(sub) ? undefined : `skill CLI \`${sub ?? ""}\` writes to a remote service`;
			}
			return undefined;
		}
		case "brew":
			return ["list", "info", "search", "--prefix", "leaves", "deps", "outdated", "config", "doctor"].includes(args[0] ?? "")
				? undefined
				: "brew changes the system";
		case "npm":
		case "pnpm":
		case "yarn":
		case "bun":
			if (args.includes("-g") || args.includes("--global") || args[0] === "publish") return `${program} global install/publish`;
			return undefined;
	}
	if (SKILL_CLIS.has(program)) {
		const sub = args.find((a) => !a.startsWith("-"));
		return sub && SKILL_CLI_READ.has(sub) ? undefined : `${program} ${sub ?? ""} writes to a remote service`;
	}
	return undefined;
}

/** Split on shell control operators. Quotes are ignored on purpose: over-splitting only over-blocks. */
function splitSegments(command: string): string[] {
	return command
		.replace(/\\\n/g, " ")
		.split(/&&|\|\||[;&|\n`]|\$\(|[()]/)
		.map((s) => s.trim())
		.filter(Boolean);
}

function tokenize(segment: string): string[] {
	const words: string[] = [];
	const re = /"((?:[^"\\]|\\.)*)"|'([^']*)'|(\S+)/g;
	for (const m of segment.matchAll(re)) words.push(m[1] ?? m[2] ?? m[3]);
	return words;
}

/** Drop env assignments, redirections and wrapper commands (`env`, `nohup`, `timeout 10`, ...). */
function unwrap(words: string[]): string[] {
	const out = words.filter((w, i) => !/^\d*[<>]/.test(w) && !/^\d*[<>]/.test(words[i - 1] ?? "x"));
	let i = 0;
	while (i < out.length) {
		const w = out[i];
		if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(w)) i++;
		else if (WRAPPERS.has(path.basename(w))) {
			i++;
			while (out[i]?.startsWith("-")) i++;
		} else if (path.basename(w) === "timeout") {
			i++;
			while (out[i]?.startsWith("-")) i++;
			i++;
		} else break;
	}
	return out.slice(i);
}

function checkRedirects(segment: string, cwd: string, roots: string[]): string | undefined {
	for (const m of segment.matchAll(/\d*>>?\s*(?!&)("[^"]*"|'[^']*'|[^\s;&|]+)/g)) {
		const target = m[1].replace(/^["']|["']$/g, "");
		if (target === "/dev/null" || target === "/dev/stdout" || target === "/dev/stderr") continue;
		if (!insideRoots(resolvePath(target, cwd), roots)) return `redirects into ${target}, outside the jj repo`;
	}
	return undefined;
}

function subcommand(args: string[], valueFlags: string[]): string | undefined {
	return afterOptions(args, valueFlags)[0];
}

function afterOptions(args: string[], valueFlags: string[]): string[] {
	const rest: string[] = [];
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a.startsWith("-")) {
			if (valueFlags.includes(a)) i++;
			continue;
		}
		rest.push(a);
	}
	return rest;
}

function flagValue(args: string[], flags: string[]): string | undefined {
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		for (const f of flags) {
			if (a === f) return args[i + 1];
			if (a.startsWith(`${f}=`)) return a.slice(f.length + 1);
			if (f.length === 2 && a.startsWith(f) && a.length > 2 && !a.startsWith("--")) return a.slice(2);
		}
	}
	return undefined;
}

export function resolvePath(p: string, cwd: string): string {
	let expanded = p.replace(/^~(?=$|\/)/, os.homedir()).replace(/^\$HOME(?=$|\/)/, os.homedir());
	if (expanded.startsWith("@")) expanded = expanded.slice(1);
	return path.resolve(cwd, expanded);
}

export function insideRoots(abs: string, roots: string[]): boolean {
	return roots.some((r) => abs === r || abs.startsWith(r.endsWith("/") ? r : `${r}/`));
}
