import {sanitizeLogText} from "./log.js";

export type ActivityLevel = "debug" | "info" | "success" | "warning" | "error";

export type ActivityEvent = {
	at: string;
	id?: string;
	level: ActivityLevel;
	message: string;
	details?: string[];
	type?: "activity" | "cloudflare" | "systemd" | "journal" | "system";
};

const MAX_LINES = 12;
const MAX_LINE_LENGTH = 500;

/** Keep diagnostic stderr useful without retaining credentials in the TUI session. */
export function activityDetails(stderr: string): string[] {
	const redacted = sanitizeLogText(stderr);
	return redacted.replace(/\r/g, "").split("\n")
		.map(line => line.trim())
		.filter(Boolean)
		.slice(-MAX_LINES)
		.map(line => line.length > MAX_LINE_LENGTH ? `${line.slice(0, MAX_LINE_LENGTH - 1)}…` : line);
}
