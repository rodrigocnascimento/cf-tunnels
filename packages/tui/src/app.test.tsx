import {afterEach, expect, test} from "bun:test";
import {cleanup, render} from "ink-testing-library";
import {App} from "./app.js";
import type {TuiOperations} from "./operations.js";

afterEach(cleanup);

test("renders the Ink operational view from contract data", async () => {
	const client: TuiOperations = {
		capabilities: async () => ({application_version: "0.6.0", operations: {}}),
		zoneCurrent: async () => ({default_zone: "example.com"}),
		zoneList: async () => ({default_zone: "example.com", zones: [{name: "example.com", is_default: true, tunnel_count: 1, route_count: 1, credential: {state: "ready", cert_present: true, cert_mode: "600", metadata_present: true, metadata_mode: "600"}}, {name: "other.example", is_default: false, tunnel_count: 0, route_count: 0, credential: {state: "missing", cert_present: false, cert_mode: null, metadata_present: false, metadata_mode: null}}]}),
		zoneUse: async zone => ({zone, persisted: true, directory_created: true}),
		list: async zone => ({scope_zone: zone ?? null, listed_at: "2026-09-25T00:00:00Z", tunnels: zone === "example.com" ? [{zone: "example.com", name: "api", uuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", unit: "cloudflared@example.com_api.service", status: "active", config: {yaml: {present: true, mode: "600"}, credential: {present: true, mode: "600"}, issues: []}, routes: [{hostname: "api.example.com", service: "http://localhost:3000"}]}] : []}),
		health: async () => ({scope_zone: "example.com", checked_at: "2026-09-25T00:00:00Z", tunnels: []}),
	};
	const view = render(<App client={client}/>);
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(view.lastFrame()).toContain("CFTUNNEL");
	expect(view.lastFrame()).not.toContain("All local zones");
	expect(view.lastFrame()).toContain("Scope: example.com");
	expect(view.lastFrame()).toContain("v0.6.0");
	expect(view.lastFrame()).toContain("example.com");
	view.stdin.write("\t");
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(view.lastFrame()).toContain("DETAILS · api");
});

test("confirms a Scope change before persisting the CLI default zone", async () => {
	const used: string[] = [];
	const client: TuiOperations = {
		capabilities: async () => ({application_version: "0.12.0", operations: {}}),
		zoneCurrent: async () => ({default_zone: used.at(-1) ?? "one.example"}),
		zoneList: async () => ({default_zone: used.at(-1) ?? "one.example", zones: ["one.example", "two.example"].map((name, index) => ({name, is_default: index === 0, tunnel_count: 0, route_count: 0, credential: {state: "ready" as const, cert_present: true, cert_mode: "600", metadata_present: true, metadata_mode: "600"}}))}),
		zoneUse: async zone => { used.push(zone); return {zone, persisted: true, directory_created: true}; },
		list: async zone => ({scope_zone: zone ?? null, listed_at: "2026-09-25T00:00:00Z", tunnels: []}),
		health: async () => ({scope_zone: "one.example", checked_at: "2026-09-25T00:00:00Z", tunnels: []}),
	};
	const view = render(<App client={client}/>);
	await new Promise(resolve => setTimeout(resolve, 20));
	view.stdin.write("\u001B[C");
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(view.lastFrame()).toContain("CHANGE ACTIVE ZONE");
	expect(used).toEqual([]);
	view.stdin.write("\u001B");
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(used).toEqual([]);
	view.stdin.write("\u001B[C");
	await new Promise(resolve => setTimeout(resolve, 20));
	view.stdin.write(" ");
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(view.lastFrame()).toContain("[x] Do not ask again in this session");
	view.stdin.write("\r");
	await new Promise(resolve => setTimeout(resolve, 30));
	expect(used).toEqual(["two.example"]);
	expect(view.lastFrame()).toContain("Scope: two.example");
});

test("registers a new zone before requesting its interactive login", async () => {
	const registered = ["one.example"];
	const used: string[] = [];
	const logins: string[] = [];
	const client: TuiOperations = {
		capabilities: async () => ({application_version: "0.12.0", operations: {}}),
		zoneCurrent: async () => ({default_zone: registered.at(-1) ?? null}),
		zoneList: async () => ({default_zone: registered.at(-1) ?? null, zones: registered.map(name => ({name, is_default: name === registered.at(-1), tunnel_count: 0, route_count: 0, credential: {state: "missing" as const, cert_present: false, cert_mode: null, metadata_present: false, metadata_mode: null}}))}),
		zoneUse: async zone => { if (!registered.includes(zone)) registered.push(zone); used.push(zone); return {zone, persisted: true, directory_created: true}; },
		list: async zone => ({scope_zone: zone ?? null, listed_at: "2026-09-25T00:00:00Z", tunnels: []}),
		health: async () => ({scope_zone: "one.example", checked_at: "2026-09-25T00:00:00Z", tunnels: []}),
	};
	const view = render(<App client={client} onLogin={async zone => { logins.push(zone); }}/>);
	await new Promise(resolve => setTimeout(resolve, 20));
	view.stdin.write("a");
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(view.lastFrame()).toContain("ADD CLOUDFLARE ZONE");
	view.stdin.write("two.example");
	await new Promise(resolve => setTimeout(resolve, 20));
	view.stdin.write("\r");
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(view.lastFrame()).toContain("ADD ZONE AND LOGIN");
	expect(used).toEqual([]);
	view.stdin.write("\r");
	await new Promise(resolve => setTimeout(resolve, 30));
	expect(used).toEqual(["two.example"]);
	expect(logins).toEqual(["two.example"]);
	expect(view.lastFrame()).toContain("Scope: two.example");
	view.stdin.write("l");
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(view.lastFrame()).toContain("LOGIN TO ACTIVE ZONE");
	view.stdin.write("\r");
	await new Promise(resolve => setTimeout(resolve, 20));
	expect(logins).toEqual(["two.example", "two.example"]);
});
