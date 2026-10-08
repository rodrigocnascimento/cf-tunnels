import {mkdir, readFile} from "node:fs/promises";
import {dirname, resolve} from "node:path";
import {cleanup, render} from "ink-testing-library";
import {App} from "../src/app.js";
import type {Health, Tunnel} from "../src/contracts.js";
import type {TuiOperations} from "../src/operations.js";

// Render the actual dashboard with public example data. This client cannot
// spawn cftunnel, contact Cloudflare, or change local credentials/services.
const version = (await readFile(new URL("../../../VERSION", import.meta.url), "utf8")).trim();
const output = resolve(process.argv[2] ?? new URL("../dist/demo-frames.json", import.meta.url).pathname);
const timestamp = "2026-10-08T12:00:00Z";
const tunnels: Tunnel[] = [
	{name: "example-com-http", zone: "example.com", uuid: "11111111-1111-4111-8111-111111111111", unit: "cloudflared@example.com_example-com-http.service", status: "active", boot_state: "enabled", config: {yaml: {present: true, mode: "600"}, credential: {present: true, mode: "600"}, issues: []}, routes: [{hostname: "app.example.com", service: "http://localhost:3000"}, {hostname: "status.example.com", service: "http://localhost:8080"}]},
	{name: "example-com-ssh", zone: "example.com", uuid: "22222222-2222-4222-8222-222222222222", unit: "cloudflared@example.com_example-com-ssh.service", status: "inactive", boot_state: "disabled", config: {yaml: {present: true, mode: "600"}, credential: {present: true, mode: "600"}, issues: []}, routes: [{hostname: "ssh.example.com", service: "ssh://localhost:22"}]},
];
const client: TuiOperations = {
	capabilities: async () => ({application_version: version, operations: {}}),
	zoneCurrent: async () => ({default_zone: "example.com"}),
	zoneList: async () => ({default_zone: "example.com", zones: [
		{name: "example.com", is_default: true, tunnel_count: 2, route_count: 3, credential: {state: "ready", cert_present: true, cert_mode: "600", metadata_present: true, metadata_mode: "600"}},
		{name: "example.net", is_default: false, tunnel_count: 0, route_count: 0, credential: {state: "missing", cert_present: false, cert_mode: null, metadata_present: false, metadata_mode: null}},
	]}),
	zoneUse: async () => { throw new Error("Demo capture does not change zones"); },
	list: async zone => ({scope_zone: zone ?? null, listed_at: timestamp, tunnels}),
	health: async name => ({scope_zone: "example.com", checked_at: timestamp, tunnels: tunnels.filter(tunnel => !name || tunnel.name === name).map(tunnel => ({zone: tunnel.zone, name: tunnel.name, unit: tunnel.unit, config: {mode: "600", uuid: tunnel.uuid, credential: {present: true, mode: "600"}}, systemd: {source: "systemd", status: tunnel.status, boot_state: tunnel.boot_state}, routes: tunnel.routes.map(route => ({...route, dns: {result: `${tunnel.uuid}.cfargotunnel.com`, checked_at: timestamp}}))}))} satisfies Health),
	hostnamePlan: async (zone, hostname, type, service) => ({zone, hostname, type, service, tunnel_name: tunnels[0]!.name, unit: tunnels[0]!.unit, yaml: `/home/demo/.cloudflared/zones/${zone}/${tunnels[0]!.name}.yml`, existing_tunnel: true, existing_hostname: false, restart_required: true, origin_tls: {server_name: null, verify: true, configured: false}, dns: {mode: "automatic"}, privilege: {sudo_required: true}}),
};

const frames: Array<{title: string; duration_ms: number; terminal: string}> = [];
const view = render(<App client={client}/>);
Object.defineProperty(view.stdout, "columns", {value: 120});
view.stdout.emit("resize");
const plain = (frame: string) => frame.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "");
const waitFor = async (text: string) => {
	for (let attempt = 0; attempt < 200; attempt++) {
		const frame = view.lastFrame();
		if (frame && plain(frame).includes(text)) return frame;
		await Bun.sleep(10);
	}
	throw new Error(`Demo did not reach ${JSON.stringify(text)}\n${plain(view.lastFrame() ?? "")}`);
};
const capture = async (title: string, duration_ms: number, expected: string) => {
	const terminal = await waitFor(expected);
	frames.push({title, duration_ms, terminal});
};
const input = async (keys: string, expected: string) => {
	view.stdin.write(keys);
	// Let Ink commit the new input handler before sending the next key.
	await Bun.sleep(50);
	await waitFor(expected);
};

try {
	await capture("Local routes, zone credentials, and systemd state", 5000, "DETAILS · example-com-http");
	await input("\u001b[B", "DETAILS · example-com-ssh");
	await capture("Running now and enabled at boot are separate states", 4000, "DETAILS · example-com-ssh");
	await input("\u001b[A", "DETAILS · example-com-http");
	await input("h", "HEALTH");
	await capture("Request a timestamped configuration, systemd, and DNS check", 5000, "cfargotunnel.com");
	await input("n", "ADD HOSTNAME · example.com");
	await input("docs", "docs▌");
	await input("\r", "http  (Left/Right changes)");
	await input("\r", "Origin service URL");
	await input("http://localhost:4321", "http://localhost:4321▌");
	await capture("Add a hostname with the keyboard", 4000, "Origin service URL");
	await input("\r", "ADD HOSTNAME PLAN");
	await capture("Review the tunnel, DNS, restart, and sudo effects before applying", 6000, "docs.example.com");
	await input("\u001b", "DETAILS · example-com-http");
	await input("\u001b[C", "example.net");
	await input("\r", "CHANGE ACTIVE ZONE");
	await capture("Changing Scope explicitly confirms the CLI default-zone change", 5000, "New Scope:     example.net");
	await mkdir(dirname(output), {recursive: true});
	await Bun.write(output, JSON.stringify({schema_version: 1, sample_data: true, columns: 120, application_version: version, frames}, null, 2) + "\n");
	process.stdout.write(`Captured ${frames.length} sample-data dashboard frames to ${output}\n`);
} finally {
	cleanup();
}
