import {constants} from "node:fs";
import {chmod, lstat, mkdir, open, readdir, unlink} from "node:fs/promises";
import {homedir} from "node:os";
import {isAbsolute, join, resolve} from "node:path";

export const EVENT_TYPES = ["activity", "cloudflare", "systemd", "journal", "system"] as const;
export const EVENT_LEVELS = ["debug", "info", "success", "warning", "error"] as const;
export type LogEventType = typeof EVENT_TYPES[number];
export type LogLevel = typeof EVENT_LEVELS[number];

export type LogEvent = {
	schema_version: 1;
	timestamp: string;
	type: LogEventType;
	level: LogLevel;
	message: string;
	context?: Record<string, unknown>;
};

export type WriteInput = Omit<LogEvent, "schema_version" | "timestamp"> & {timestamp?: string};
export type QueryOptions = {since?: string; until?: string; type?: LogEventType[]; level?: LogLevel[]; zone?: string; hostname?: string; limit?: number; order?: "asc" | "desc"};

const REDACTED = "[REDACTED]";
const MAX_MESSAGE = 4000;
const MAX_STRING = 2000;
const MAX_EVENT_BYTES = 16_384;
const DEFAULT_RETENTION_DAYS = 30;
const FILE_RE = /^\d{4}-\d{2}-\d{2}\.jsonl$/;
const SECRET_KEY_RE = /(?:^|_)(?:access_?)?token(?:$|_)|api_?key|authorization|cookie|secret|password|passwd|credential|private_?key|pem|certificate|cert(?:$|_)/i;

function normalizeKey(value: string) {
	return value.replace(/([a-z0-9])([A-Z])/g, "$1_$2").replace(/[-\s]/g, "_").toLowerCase();
}

export function sanitizeLogText(input: string): string {
	let value = input
		.replace(/-----BEGIN [^-\r\n]*-----[\s\S]*?(?:-----END [^-\r\n]*-----|$)/gi, REDACTED)
		.replace(/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi, `Bearer ${REDACTED}`)
		.replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{4,})?/g, REDACTED)
		.replace(/([\"']?(?:access[_-]?token|token|api[_-]?key|authorization|cookie|secret|password|passwd|credential|private[_-]?key|pem|certificate|cert)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;}]+)/gi, `$1${REDACTED}`)
		.replace(/\b[A-Za-z0-9+/=_-]{40,}\b/g, REDACTED);
	return value.length > MAX_STRING ? `${value.slice(0, MAX_STRING)}…` : value;
}

function redactValue(value: unknown, key = "", depth = 0): unknown {
	if (SECRET_KEY_RE.test(normalizeKey(key))) return REDACTED;
	if (typeof value === "string") return sanitizeLogText(value);
	if (Array.isArray(value)) return depth > 5 ? REDACTED : value.slice(0, 100).map(item => redactValue(item, "", depth + 1));
	if (value && typeof value === "object") {
		if (depth > 5) return REDACTED;
		return Object.fromEntries(Object.entries(value as Record<string, unknown>).slice(0, 100).map(([childKey, childValue]) => [childKey, redactValue(childValue, childKey, depth + 1)]));
	}
	if (typeof value === "number" || typeof value === "boolean" || value === null) return value;
	return REDACTED;
}

export function sanitizeEvent(input: WriteInput | LogEvent): LogEvent {
	if (!EVENT_TYPES.includes(input.type) || !EVENT_LEVELS.includes(input.level)) throw new Error("unsupported log event type or level");
	const timestamp = input.timestamp ?? new Date().toISOString();
	if (!Number.isFinite(Date.parse(timestamp)) || !/^\d{4}-\d\d-\d\dT/.test(timestamp)) throw new Error("timestamp must be an RFC3339 date-time");
	if (typeof input.message !== "string" || input.message.length === 0) throw new Error("message is required");
	const event: LogEvent = {
		schema_version: 1,
		timestamp: new Date(timestamp).toISOString(),
		type: input.type,
		level: input.level,
		message: sanitizeLogText(input.message.slice(0, MAX_MESSAGE)),
	};
	if (input.context) event.context = redactValue(input.context) as Record<string, unknown>;
	if (Buffer.byteLength(JSON.stringify(event)) > MAX_EVENT_BYTES) {
		event.message = `${event.message.slice(0, 500)} [details omitted: event size limit]`;
		event.context = {details: "[details omitted: event size limit]"};
	}
	return event;
}

function stateDirectory(): string {
	const configured = process.env.XDG_STATE_HOME;
	if (configured && !isAbsolute(configured)) throw new Error("XDG_STATE_HOME must be an absolute path");
	const base = configured || join(homedir(), ".local", "state");
	return resolve(base, "cftunnel", "logs");
}

async function assertSafeDirectory(path: string): Promise<void> {
	const resolved = resolve(path);
	const home = resolve(homedir());
	if (resolved !== home && !resolved.startsWith(`${home}/`) && !process.env.XDG_STATE_HOME) throw new Error("log directory is outside the user state directory");
	const parts = resolved.split("/").filter(Boolean);
	let current = "/";
	for (const part of parts) {
		current = join(current, part);
		let info;
		try {
			info = await lstat(current);
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
			try { await mkdir(current, {mode: 0o700}); }
			catch (createError) { if ((createError as NodeJS.ErrnoException).code !== "EEXIST") throw createError; }
			info = await lstat(current);
		}
		if (info.isSymbolicLink() || !info.isDirectory()) throw new Error("log path contains a symlink or non-directory component");
		if (current === resolved) {
			if (info.uid !== process.getuid?.()) throw new Error("log directory must be owned by the current user");
			await chmod(resolved, 0o700);
		}
	}
	await chmod(resolved, 0o700);
}

export async function writeEvent(input: WriteInput): Promise<LogEvent> {
	const event = sanitizeEvent(input);
	const directory = stateDirectory();
	await assertSafeDirectory(directory);
	const date = event.timestamp.slice(0, 10);
	const file = join(directory, `${date}.jsonl`);
	let handle;
	try {
		handle = await open(file, constants.O_APPEND | constants.O_CREAT | constants.O_WRONLY | (constants.O_NOFOLLOW ?? 0), 0o600);
		const info = await handle.stat();
		if (!info.isFile()) throw new Error("log file is not a regular file");
		await handle.chmod(0o600);
		const line = `${JSON.stringify(event)}\n`;
		const written = await handle.write(line);
		if (written.bytesWritten !== Buffer.byteLength(line)) throw new Error("incomplete log record write");
	} finally {
		await handle?.close();
	}
	await pruneOldLogs(directory);
	return event;
}

async function pruneOldLogs(directory: string): Promise<void> {
	const configured = Number.parseInt(process.env.CFTUNNEL_LOG_RETENTION_DAYS ?? "", 10);
	const retention = Number.isInteger(configured) && configured >= 1 && configured <= 3650 ? configured : DEFAULT_RETENTION_DAYS;
	const cutoff = new Date();
	cutoff.setUTCDate(cutoff.getUTCDate() - retention);
	for (const name of await readdir(directory)) {
		if (!FILE_RE.test(name)) continue;
		const fileDate = Date.parse(`${name.slice(0, 10)}T00:00:00.000Z`);
		if (!Number.isFinite(fileDate) || fileDate >= cutoff.getTime()) continue;
		const path = join(directory, name);
		const info = await lstat(path);
		if (info.isFile() && !info.isSymbolicLink()) await unlink(path);
	}
}

function matches(event: LogEvent, options: QueryOptions): boolean {
	const time = Date.parse(event.timestamp);
	if (options.since && time < Date.parse(options.since)) return false;
	if (options.until && time > Date.parse(options.until)) return false;
	if (options.type?.length && !options.type.includes(event.type)) return false;
	if (options.level?.length && !options.level.includes(event.level)) return false;
	if (options.zone && event.context?.zone !== options.zone) return false;
	if (options.hostname && event.context?.hostname !== options.hostname) return false;
	return true;
}

export async function queryEvents(options: QueryOptions = {}) {
	const directory = stateDirectory();
	try { await assertSafeDirectory(directory); } catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return {events: [], warnings: [] as string[]};
		throw error;
	}
	const limit = Number.isInteger(options.limit) && (options.limit ?? 0) > 0 ? Math.min(options.limit!, 1000) : 100;
	const startDay = options.since?.slice(0, 10);
	const endDay = options.until?.slice(0, 10);
	const names = (await readdir(directory)).filter(name => FILE_RE.test(name) && (!startDay || name.slice(0, 10) >= startDay) && (!endDay || name.slice(0, 10) <= endDay)).sort();
	const warnings: string[] = [];
	const events: LogEvent[] = [];
	for (const name of names) {
		const path = join(directory, name);
		const info = await lstat(path);
		if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid?.()) { warnings.push(`${name}: skipped unsafe log file`); continue; }
		if (info.size > 16 * 1024 * 1024) { warnings.push(`${name}: skipped oversized log file`); continue; }
		const data = await Bun.file(path).text();
		for (const [index, line] of data.split("\n").entries()) {
			if (!line.trim()) continue;
			try {
				const event = sanitizeEvent(JSON.parse(line) as LogEvent);
				if (matches(event, options)) events.push(event);
			} catch {
				warnings.push(`${name}:${index + 1}: skipped malformed event`);
			}
		}
	}
	events.sort((a, b) => Date.parse(a.timestamp) - Date.parse(b.timestamp));
	if (options.order === "desc") events.reverse();
	return {events: events.slice(0, limit), warnings};
}

export async function runLogCli(args: string[], stdin = ""): Promise<number> {
	const [operation, ...rest] = args;
	if (operation === "--help" || operation === "-h" || operation === "help") {
		process.stdout.write(`Usage: cftunnel log <write|query> [options]
  log write --type TYPE --level LEVEL --message TEXT [--zone NAME] [--hostname HOST] [--operation NAME] [--timestamp RFC3339]
  log write --stdin-json
  log query [--since RFC3339] [--until RFC3339] [--type TYPE] [--level LEVEL] [--zone NAME] [--hostname HOST] [--limit N] [--order asc|desc] [--output json|text]
`);
		return 0;
	}
	if (operation === "write") {
		const input = parseArgs(rest);
		const event = input.stdinJson ? JSON.parse(stdin) as WriteInput : {
			type: input.writeType,
			level: input.writeLevel,
			message: input.message,
			timestamp: input.writeTimestamp,
			context: Object.fromEntries(Object.entries({zone: input.zone, hostname: input.hostname, operation: input.operation}).filter(([, value]) => value !== undefined)),
		};
		if (!event.type || !event.level || !event.message) throw new Error("log write requires --type, --level, and --message");
		await writeEvent(event as WriteInput);
		return 0;
	}
	if (operation === "query") {
		const flags = parseArgs(rest);
		const result = await queryEvents({since: flags.since, until: flags.until, type: flags.types, level: flags.levels, zone: flags.zone, hostname: flags.hostname, limit: flags.limit, order: flags.order});
		if (flags.output === "text") {
			for (const event of result.events) process.stdout.write(`${event.timestamp}\t[${event.type.toUpperCase()}]\t${icon(event.level)}\t${event.message}\n`);
			for (const warning of result.warnings) process.stderr.write(`warning: ${warning}\n`);
		} else process.stdout.write(`${JSON.stringify({schema_version: 1, operation: "log.query", ok: true, data: result, warnings: result.warnings})}\n`);
		return 0;
	}
	throw new Error("usage: cftunnel log <write|query> [options]");
}

function parseArgs(args: string[]) {
	const result: {stdinJson?: boolean; event?: string; since?: string; until?: string; types?: LogEventType[]; levels?: LogLevel[]; zone?: string; hostname?: string; limit?: number; order?: "asc" | "desc"; output?: "json" | "text"; writeType?: LogEventType; writeLevel?: LogLevel; message?: string; writeTimestamp?: string; operation?: string} = {};
	for (let i = 0; i < args.length; i++) {
		const arg = args[i];
		if (arg === "--stdin-json") result.stdinJson = true;
		else if (arg === "--type") { const value = checked(arg, args[++i], EVENT_TYPES); result.types = [...(result.types ?? []), value]; result.writeType = value; }
		else if (arg === "--level") { const value = checked(arg, args[++i], EVENT_LEVELS); result.levels = [...(result.levels ?? []), value]; result.writeLevel = value; }
		else if (arg === "--event") result.event = args[++i];
		else if (["--since", "--until", "--zone", "--hostname", "--limit", "--order", "--output", "--message", "--timestamp", "--operation"].includes(arg ?? "")) {
			const value = args[++i]; if (!value) throw new Error(`${arg} requires a value`);
			if (arg === "--since" || arg === "--until" || arg === "--timestamp") { if (!Number.isFinite(Date.parse(value))) throw new Error(`${arg} must be a date-time`); if (arg === "--timestamp") result.writeTimestamp = new Date(value).toISOString(); else if (arg === "--since") result.since = new Date(value).toISOString(); else result.until = new Date(value).toISOString(); }
			else if (arg === "--zone") result.zone = value;
			else if (arg === "--hostname") result.hostname = value;
			else if (arg === "--message") result.message = value;
			else if (arg === "--operation") result.operation = value;
			else if (arg === "--limit") { const limit = Number(value); if (!Number.isInteger(limit) || limit < 1) throw new Error("--limit must be a positive integer"); result.limit = limit; }
			else if (arg === "--order") { if (value !== "asc" && value !== "desc") throw new Error("--order must be asc or desc"); result.order = value; }
			else if (arg === "--output") { if (value !== "json" && value !== "text") throw new Error("--output must be json or text"); result.output = value; }
		} else throw new Error(`unknown log option: ${arg}`);
	}
	return result;
}

function checked<T extends string>(flag: string, value: string | undefined, values: readonly T[]): T {
	if (!value || !values.includes(value as T)) throw new Error(`${flag} requires one of: ${values.join(", ")}`);
	return value as T;
}

function icon(level: LogLevel) {
	return level === "success" ? "✓" : level === "error" ? "✗" : level === "warning" ? "!" : "·";
}
