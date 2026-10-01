import {expect, test} from "bun:test";
import {CftunnelOperations, type ProcessRunner} from "./operations.js";

test("rejects a malformed contract response", async () => {
	const runner: ProcessRunner = {run: async () => ({exitCode: 0, stdout: "not json", stderr: ""})};
	await expect(new CftunnelOperations(runner).list()).rejects.toThrow("invalid JSON");
});

test("sends only argument arrays and validates the expected operation", async () => {
	let received: string[] = [];
	const runner: ProcessRunner = {run: async args => {
		received = args;
		return {exitCode: 0, stderr: "", stdout: JSON.stringify({schema_version: 1, operation: "tunnel.list", ok: true, data: {scope_zone: null, listed_at: "2026-09-25T00:00:00Z", tunnels: []}, warnings: []})};
	}};
	await expect(new CftunnelOperations(runner).list()).resolves.toEqual({scope_zone: null, listed_at: "2026-09-25T00:00:00Z", tunnels: []});
	expect(received).toEqual(["--all-zones", "list", "--output", "json"]);
});

test("passes an explicit zone only through argument-array scope flags", async () => {
	let received: string[] = [];
	const runner: ProcessRunner = {run: async args => {
		received = args;
		return {exitCode: 0, stderr: "", stdout: JSON.stringify({schema_version: 1, operation: "tunnel.list", ok: true, data: {scope_zone: "example.com", listed_at: "2026-09-25T00:00:00Z", tunnels: []}, warnings: []})};
	}};
	await new CftunnelOperations(runner).list("example.com");
	expect(received).toEqual(["--zone", "example.com", "list", "--output", "json"]);
});

test("sets an already-discovered zone through the JSON contract", async () => {
	let received: string[] = [];
	const runner: ProcessRunner = {run: async args => {
		received = args;
		return {exitCode: 0, stderr: "", stdout: JSON.stringify({schema_version: 1, operation: "zone.use", ok: true, data: {zone: "example.com", persisted: true, directory_created: true}, warnings: []})};
	}};
	await expect(new CftunnelOperations(runner).zoneUse("example.com")).resolves.toEqual({zone: "example.com", persisted: true, directory_created: true});
	expect(received).toEqual(["zone", "use", "example.com", "--output", "json"]);
});

test("plans a hostname addition through an argument-array contract", async () => {
	let received: string[] = [];
	const runner: ProcessRunner = {run: async args => {
		received = args;
		return {exitCode: 0, stderr: "", stdout: JSON.stringify({schema_version: 1, operation: "hostname.add.plan", ok: true, data: {zone: "example.com", hostname: "app.example.com", type: "http", service: "http://localhost:8080", tunnel_name: "example-com-http", unit: "cloudflared@example.com_example-com-http.service", yaml: "/tmp/example.yml", existing_tunnel: true, existing_hostname: false, restart_required: true, origin_tls: {server_name: null, verify: true, configured: false}, dns: {mode: "automatic"}, privilege: {sudo_required: true}}, warnings: []})};
	}};
	await expect(new CftunnelOperations(runner).hostnamePlan("example.com", "app.example.com", "http", "http://localhost:8080")).resolves.toMatchObject({tunnel_name: "example-com-http", restart_required: true});
	expect(received).toEqual(["--zone", "example.com", "add", "--hostname", "app.example.com", "--type", "http", "--service", "http://localhost:8080", "--plan", "--output", "json"]);
});

test("passes explicit HTTPS origin TLS choices through the hostname plan contract", async () => {
	let received: string[] = [];
	const runner: ProcessRunner = {run: async args => {
		received = args;
		return {exitCode: 0, stderr: "", stdout: JSON.stringify({schema_version: 1, operation: "hostname.add.plan", ok: true, data: {zone: "example.com", hostname: "app.example.com", type: "http", service: "https://127.0.0.1:443", tunnel_name: "example-com-http", unit: "cloudflared@example.com_example-com-http.service", yaml: "/tmp/example.yml", existing_tunnel: false, existing_hostname: false, restart_required: false, origin_tls: {server_name: "app.example.com", verify: false, configured: true}, dns: {mode: "automatic"}, privilege: {sudo_required: true}}, warnings: []})};
	}};
	await new CftunnelOperations(runner).hostnamePlan("example.com", "app.example.com", "http", "https://127.0.0.1:443", "app.example.com", false);
	expect(received).toEqual(["--zone", "example.com", "add", "--hostname", "app.example.com", "--type", "http", "--service", "https://127.0.0.1:443", "--no-tls-verify", "--origin-server-name", "app.example.com", "--plan", "--output", "json"]);
});

test("runs an aggregate health check without a tunnel name", async () => {
	let received: string[] = [];
	const runner: ProcessRunner = {run: async args => {
		received = args;
		return {exitCode: 0, stderr: "", stdout: JSON.stringify({schema_version: 1, operation: "tunnel.health", ok: true, data: {scope_zone: null, checked_at: "2026-09-25T00:00:00Z", tunnels: []}, warnings: []})};
	}};
	await new CftunnelOperations(runner).health();
	expect(received).toEqual(["--all-zones", "health", "--output", "json"]);
});
