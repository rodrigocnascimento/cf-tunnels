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

test("runs an aggregate health check without a tunnel name", async () => {
	let received: string[] = [];
	const runner: ProcessRunner = {run: async args => {
		received = args;
		return {exitCode: 0, stderr: "", stdout: JSON.stringify({schema_version: 1, operation: "tunnel.health", ok: true, data: {scope_zone: null, checked_at: "2026-09-25T00:00:00Z", tunnels: []}, warnings: []})};
	}};
	await new CftunnelOperations(runner).health();
	expect(received).toEqual(["--all-zones", "health", "--output", "json"]);
});
