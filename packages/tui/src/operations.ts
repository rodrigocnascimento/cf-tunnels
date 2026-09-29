import type {CapabilityData, Health, HostnamePlan, Inventory, JsonResponse, ZoneContext, ZoneInventory, ZoneUse} from "./contracts.js";

export interface ProcessRunner {
	run(args: string[]): Promise<{exitCode: number; stdout: string; stderr: string}>;
}

export class BunProcessRunner implements ProcessRunner {
	constructor(private readonly binary = process.env.CFTUNNEL_BIN ?? "cftunnel") {}

	async run(args: string[]) {
		const process = Bun.spawn([this.binary, ...args], {stdout: "pipe", stderr: "pipe"});
		const [stdout, stderr, exitCode] = await Promise.all([
			new Response(process.stdout).text(),
			new Response(process.stderr).text(),
			process.exited,
		]);
		return {exitCode, stdout, stderr};
	}
}

export interface TuiOperations {
	capabilities(): Promise<CapabilityData>;
	zoneCurrent(): Promise<ZoneContext>;
	zoneList(): Promise<ZoneInventory>;
	zoneUse(zone: string): Promise<ZoneUse>;
	hostnamePlan(zone: string, hostname: string, type: HostnamePlan["type"], service: string, originServerName?: string | null, verifyTls?: boolean): Promise<HostnamePlan>;
	list(zone?: string | null): Promise<Inventory>;
	health(name?: string, zone?: string | null): Promise<Health>;
}

export class CftunnelOperations implements TuiOperations {
	constructor(private readonly runner: ProcessRunner = new BunProcessRunner()) {}

	async capabilities() {
		return this.call<CapabilityData>("capabilities", ["capabilities", "--output", "json"]);
	}

	async zoneCurrent() {
		return this.call<ZoneContext>("zone.current", ["zone", "current", "--output", "json"]);
	}

	async zoneList() {
		return this.call<ZoneInventory>("zone.list", ["zone", "list", "--output", "json"]);
	}

	async zoneUse(zone: string) {
		return this.call<ZoneUse>("zone.use", ["zone", "use", zone, "--output", "json"]);
	}

	async hostnamePlan(zone: string, hostname: string, type: HostnamePlan["type"], service: string, originServerName?: string | null, verifyTls = true) {
		const tlsArgs = service.startsWith("https://") ? [verifyTls ? "--verify-tls" : "--no-tls-verify", ...(originServerName ? ["--origin-server-name", originServerName] : [])] : [];
		return this.call<HostnamePlan>("hostname.add.plan", ["--zone", zone, "add", "--hostname", hostname, "--type", type, "--service", service, ...tlsArgs, "--plan", "--output", "json"]);
	}

	async list(zone: string | null = null) {
		return this.call<Inventory>("tunnel.list", [...scopeArgs(zone), "list", "--output", "json"]);
	}

	async health(name?: string, zone?: string | null) {
		const nameArgs = name ? ["--name", name] : [];
		return this.call<Health>("tunnel.health", [...scopeArgs(zone ?? null), "health", ...nameArgs, "--output", "json"]);
	}

	private async call<T>(operation: string, args: string[]): Promise<T> {
		const result = await this.runner.run(args);
		if (result.exitCode !== 0) {
			throw new Error(result.stderr.trim() || `cftunnel ${operation} failed with exit ${result.exitCode}`);
		}
		let parsed: unknown;
		try {
			parsed = JSON.parse(result.stdout);
		} catch {
			throw new Error(`cftunnel ${operation} returned invalid JSON`);
		}
		if (!isEnvelope(parsed, operation)) {
			throw new Error(`cftunnel returned an incompatible response for ${operation}`);
		}
		return parsed.data as T;
	}
}

function scopeArgs(zone: string | null): string[] {
	return zone === null ? ["--all-zones"] : ["--zone", zone];
}

function isEnvelope(value: unknown, operation: string): value is JsonResponse<unknown> {
	if (typeof value !== "object" || value === null) return false;
	const response = value as Partial<JsonResponse<unknown>>;
	return response.schema_version === 1 && response.operation === operation && response.ok === true && "data" in response && Array.isArray(response.warnings);
}
