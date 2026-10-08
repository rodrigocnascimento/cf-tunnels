export type JsonResponse<T> = {
	schema_version: number;
	operation: string;
	ok: true;
	data: T;
	warnings: string[];
};

export type Tunnel = {
	zone: string;
	name: string;
	uuid: string | null;
	unit: string;
	status: "active" | "enabled" | "inactive" | "failed" | "unavailable";
	boot_state: string;
	config: {yaml: {present: boolean; mode: string | null}; credential: {present: boolean; mode: string | null}; issues: string[]};
	routes: Array<{hostname: string; service: string}>;
};

export type Inventory = {scope_zone: string | null; listed_at: string; tunnels: Tunnel[]};
export type ZoneContext = {default_zone: string | null};
export type Zone = {
	name: string;
	is_default: boolean;
	tunnel_count: number;
	route_count: number;
	credential: {state: "ready" | "missing" | "invalid"; cert_present: boolean; cert_mode: string | null; metadata_present: boolean; metadata_mode: string | null};
};
export type ZoneInventory = {default_zone: string | null; zones: Zone[]};
export type ZoneUse = {zone: string; persisted: true; directory_created: boolean};
export type HostnamePlan = {
	zone: string | null;
	hostname: string;
	type: "http" | "ssh" | "tcp";
	service: string;
	tunnel_name: string;
	unit: string;
	yaml: string;
	existing_tunnel: boolean;
	existing_hostname: boolean;
	restart_required: boolean;
	origin_tls: {server_name: string | null; verify: boolean; configured: boolean};
	dns: {mode: "automatic"};
	privilege: {sudo_required: true};
};
export type HostnameRemovalPlan = {
	zone: string;
	hostname: string;
	tunnel_name: string;
	yaml: string;
	remaining_hostname_count: number;
	dns: {action: "unchanged"; reason: string};
	privilege: {sudo_required: true};
};
export type ActivityLogEvent = {
	schema_version: 1;
	timestamp: string;
	type: "activity" | "cloudflare" | "systemd" | "journal" | "system";
	level: "debug" | "info" | "success" | "warning" | "error";
	message: string;
	context?: Record<string, unknown>;
};
export type Health = {
	scope_zone: string | null;
	checked_at: string;
	tunnels: Array<{
		zone: string;
		name: string;
		unit: string;
		config: {mode: string | null; uuid: string | null; credential: {present: boolean; mode: string | null}};
		systemd: {source: "systemd"; status: string; boot_state: string};
		routes: Array<{hostname: string; service: string; dns: {result: string | null; checked_at: string}}>
	}>;
};

export type CapabilityData = {application_version: string; operations: Record<string, unknown>};
