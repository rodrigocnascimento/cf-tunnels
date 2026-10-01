import {render} from "ink";
import {App, type ActivityEvent} from "./app.js";
import {activityDetails} from "./activity.js";
import {CftunnelOperations} from "./operations.js";
import {runLogCli, sanitizeLogText} from "./log.js";

const runtimeArgs = process.argv[1]?.endsWith(".tsx") ? process.argv.slice(2) : process.argv.slice(1);
const logInvocation = process.env.CFTUNNEL_RUNTIME_MODE === "log" || runtimeArgs[0] === "log";
if (logInvocation) {
	const input = runtimeArgs.includes("--stdin-json") ? await new Response(Bun.stdin.stream()).text() : "";
	const modeIndex = runtimeArgs.indexOf("log");
	const logArgs = modeIndex >= 0 ? runtimeArgs.slice(modeIndex + 1) : runtimeArgs;
	try { process.exitCode = await runLogCli(logArgs, input); }
	catch (error) { process.stderr.write(`cftunnel log: ${sanitizeLogText(error instanceof Error ? error.message : "operation failed")}\n`); process.exitCode = 1; }
}

const client = new CftunnelOperations();
const binary = process.env.CFTUNNEL_BIN ?? "cftunnel";
let instance: ReturnType<typeof render>;
const activity: ActivityEvent[] = [];

const record = (level: ActivityEvent["level"], message: string, details?: string[]) => {
	activity.push({at: new Date().toISOString().slice(11, 19), type: "activity", level, message, details});
	if (activity.length > 40) activity.splice(0, activity.length - 40);
};

const clearScreen = () => {
	if (process.stdout.isTTY) process.stdout.write("\u001B[2J\u001B[H");
};

const start = () => {
	clearScreen();
	instance = render(<App client={client} onLogin={runLogin} onApplyHostname={applyHostname} onRemoveHostname={removeHostname} activity={activity}/>);
};

const runExternal = async (label: string, args: string[], streamStderr = false) => {
	record("info", `Starting ${label}`);
	instance.unmount();
	clearScreen();
	const child = Bun.spawn([binary, ...args], {stdin: "inherit", stdout: "inherit", stderr: streamStderr ? "inherit" : "pipe", env: {...Bun.env, CFTUNNEL_TUI_CONTEXT: "1"}});
	if (streamStderr) {
		// Interactive authentication can print its browser URL on stderr before
		// waiting for the user. Stream it directly to the terminal; never retain
		// authentication output in the persistent activity log.
		const exitCode = await child.exited;
		if (exitCode !== 0) {
			try {
				await client.writeActivity?.({type: "activity", level: "error", message: `${label} failed (exit ${exitCode})`});
			} catch {
				record("warning", "Observability warning: operation failure could not be persisted");
			}
		}
		start();
		return;
	}
	const [stderr, exitCode] = await Promise.all([new Response(child.stderr).text(), child.exited]);
	const details = activityDetails(stderr);
	if (exitCode !== 0 || details.length) {
		try {
			await client.writeActivity?.({type: "activity", level: exitCode === 0 ? "warning" : "error", message: exitCode === 0 ? `${label} completed with diagnostic output` : `${label} failed (exit ${exitCode})`, context: {diagnostic: stderr || "The command produced no diagnostic text on stderr."}});
		} catch {
			record("warning", "Observability warning: operation diagnostics could not be persisted");
		}
	}
	start();
};

const runLogin = async (zone: string) => {
	await runExternal(`Zone login for ${zone}`, ["--zone", zone, "zone", "login"], true);
};

const applyHostname = async ({zone, hostname, type, service, originServerName, verifyTls}: {zone: string; hostname: string; type: "http" | "ssh" | "tcp"; service: string; originServerName: string | null; verifyTls: boolean}) => {
	const tlsArgs = service.startsWith("https://") ? [verifyTls ? "--verify-tls" : "--no-tls-verify", ...(originServerName ? ["--origin-server-name", originServerName] : [])] : [];
	await runExternal(`Hostname ${hostname}`, ["--zone", zone, "add", "--hostname", hostname, "--type", type, "--service", service, ...tlsArgs, "--yes"]);
};

const removeHostname = async ({zone, hostname}: {zone: string; hostname: string}) => {
	await runExternal(`Remove hostname ${hostname}`, ["--zone", zone, "hostname", "remove", "--hostname", hostname, "--yes"]);
};

if (!logInvocation) start();
