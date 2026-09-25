import {afterEach, expect, test} from "bun:test";
import {cleanup, render} from "ink-testing-library";
import {App} from "./app.js";
import type {ReadOnlyOperations} from "./operations.js";

afterEach(cleanup);

test("renders the Ink operational view from contract data", async () => {
	const client: ReadOnlyOperations = {
		capabilities: async () => ({application_version: "0.6.0", operations: {}}),
		zoneCurrent: async () => ({default_zone: "example.com"}),
		zoneList: async () => ({default_zone: "example.com", zones: [{name: "example.com", is_default: true, tunnel_count: 1, route_count: 1, credential: {state: "ready", cert_present: true, cert_mode: "600", metadata_present: true, metadata_mode: "600"}}]}),
		list: async () => ({scope_zone: null, listed_at: "2026-09-25T00:00:00Z", tunnels: [{zone: "example.com", name: "api", uuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", unit: "cloudflared@example.com_api.service", status: "active", config: {yaml: {present: true, mode: "600"}, credential: {present: true, mode: "600"}, issues: []}, routes: [{hostname: "api.example.com", service: "http://localhost:3000"}]}]}),
		health: async () => ({scope_zone: "example.com", checked_at: "2026-09-25T00:00:00Z", tunnels: []}),
	};
	const view = render(<App client={client}/>);
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(view.lastFrame()).toContain("CFTUNNEL");
	expect(view.lastFrame()).toContain("All local zones");
	expect(view.lastFrame()).toContain("example.com");
	view.stdin.write("\t");
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(view.lastFrame()).toContain("DETAILS · api");
});
