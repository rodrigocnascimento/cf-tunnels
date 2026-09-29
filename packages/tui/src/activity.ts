export type ActivityLevel = "info" | "success" | "error";

export type ActivityEvent = {
	at: string;
	level: ActivityLevel;
	message: string;
	details?: string[];
};

const MAX_LINES = 12;
const MAX_LINE_LENGTH = 500;

/** Keep diagnostic stderr useful without retaining credentials in the TUI session. */
export function activityDetails(stderr: string): string[] {
	const redacted = stderr
		.replace(/-----BEGIN [^-]+-----[\s\S]*?-----END [^-]+-----/g, "[redacted PEM]")
		.replace(/([\"']?\b(?:token|secret|password|authorization)\b[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|\S+)/gi, "$1[redacted]")
		.replace(/\bBearer\s+\S+/gi, "Bearer [redacted]");
	return redacted.replace(/\r/g, "").split("\n")
		.map(line => line.trim())
		.filter(Boolean)
		.slice(-MAX_LINES)
		.map(line => line.length > MAX_LINE_LENGTH ? `${line.slice(0, MAX_LINE_LENGTH - 1)}…` : line);
}
