import {render} from "ink";
import {App, type ActivityEvent} from "./app.js";
import {activityDetails} from "./activity.js";
import {CftunnelOperations} from "./operations.js";

const client = new CftunnelOperations();
const binary = process.env.CFTUNNEL_BIN ?? "cftunnel";
let instance: ReturnType<typeof render>;
const activity: ActivityEvent[] = [];

const record = (level: ActivityEvent["level"], message: string, details?: string[]) => {
	activity.push({at: new Date().toISOString().slice(11, 19), level, message, details});
	if (activity.length > 40) activity.splice(0, activity.length - 40);
};

const clearScreen = () => {
	if (process.stdout.isTTY) process.stdout.write("\u001B[2J\u001B[H");
};

const start = () => {
	clearScreen();
instance = render(<App client={client} onLogin={runLogin} onApplyHostname={applyHostname} onRemoveHostname={removeHostname} activity={activity}/>);
};

const runExternal = async (label: string, args: string[]) => {
	record("info", `Started: cftunnel ${args.join(" ")}`);
	instance.unmount();
	clearScreen();
	const child = Bun.spawn([binary, ...args], {stdin: "inherit", stdout: "inherit", stderr: "pipe"});
	const [stderr, exitCode] = await Promise.all([new Response(child.stderr).text(), child.exited]);
	const details = activityDetails(stderr);
	if (exitCode === 0) record("success", `${label} completed successfully`);
	else record("error", `${label} failed (exit ${exitCode}). Read the indented diagnostic below; it remains until you quit the TUI.`, details.length ? details : ["The command produced no diagnostic text on stderr."]);
	if (exitCode === 0 && details.length) record("info", `${label} completed with diagnostic output.`, details);
	start();
};

const runLogin = async (zone: string) => {
	await runExternal(`Zone login for ${zone}`, ["--zone", zone, "zone", "login"]);
};

const applyHostname = async ({zone, hostname, type, service, originServerName, verifyTls}: {zone: string; hostname: string; type: "http" | "ssh" | "tcp"; service: string; originServerName: string | null; verifyTls: boolean}) => {
	const tlsArgs = service.startsWith("https://") ? [verifyTls ? "--verify-tls" : "--no-tls-verify", ...(originServerName ? ["--origin-server-name", originServerName] : [])] : [];
	await runExternal(`Hostname ${hostname}`, ["--zone", zone, "add", "--hostname", hostname, "--type", type, "--service", service, ...tlsArgs, "--yes"]);
};

const removeHostname = async ({zone, hostname}: {zone: string; hostname: string}) => {
	await runExternal(`Remove hostname ${hostname}`, ["--zone", zone, "hostname", "remove", "--hostname", hostname, "--yes"]);
};

start();
