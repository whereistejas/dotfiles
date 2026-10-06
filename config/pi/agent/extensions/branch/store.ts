import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const ROOT = path.join(os.homedir(), ".pi", "agent", "branches");

export interface Meta {
	id: string;
	name: string;
	flow: "tool" | "bg";
	workerFile: string;
	receiverFile: string;
	cwd: string;
	workspace?: string;
	model?: string;
	/** nvim buffer of the worker's terminal. */
	buf?: number;
	createdAt: string;
}

export interface Status {
	state: "running" | "idle";
	lastReportId?: string;
}

export interface Exit {
	code: number;
	tail: string[];
}

export interface Message {
	id: string;
	text: string;
}

export type Box = "to-receiver" | "to-worker";

export const branchDir = (id: string) => path.join(ROOT, id);
const metaFile = (id: string) => path.join(branchDir(id), "meta.json");
export const statusFile = (id: string) => path.join(branchDir(id), "status.json");
export const exitFile = (id: string) => path.join(branchDir(id), "exit.json");

export function readJson<T>(file: string): T | undefined {
	try {
		return JSON.parse(fs.readFileSync(file, "utf8")) as T;
	} catch {
		return undefined;
	}
}

export function writeJson(file: string, data: unknown): void {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	const tmp = `${file}.${process.pid}.tmp`;
	fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
	fs.renameSync(tmp, file);
}

export const saveMeta = (meta: Meta) => writeJson(metaFile(meta.id), meta);
export const loadMeta = (id: string) => readJson<Meta>(metaFile(id));

export function listMetas(): Meta[] {
	if (!fs.existsSync(ROOT)) return [];
	return fs
		.readdirSync(ROOT)
		.map(loadMeta)
		.filter((m): m is Meta => m !== undefined);
}

export function post(id: string, box: Box, message: Message): void {
	writeJson(path.join(branchDir(id), box, `${message.id}.json`), message);
}

/** Messages a box holds in `state`, oldest first. A message moves through states by renaming its file. */
export function inbox(id: string, box: Box, state = "json"): { file: string; message: Message }[] {
	const dir = path.join(branchDir(id), box);
	if (!fs.existsSync(dir)) return [];
	return fs
		.readdirSync(dir)
		.filter((f) => f.endsWith(`.${state}`))
		.sort()
		.flatMap((f) => {
			const file = path.join(dir, f);
			const message = readJson<Message>(file);
			return message ? [{ file, message }] : [];
		});
}

export function moveTo(file: string, state: string): void {
	fs.renameSync(file, file.replace(/\.[^.]+$/, `.${state}`));
}

export function newId(): string {
	return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
}
