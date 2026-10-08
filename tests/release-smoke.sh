#!/usr/bin/env bash
set -euo pipefail

# Opt-in networked verification of the public release in a fresh rootless
# systemd container. It does not mount the host's home or create remote tunnels.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v podman >/dev/null 2>&1 || { echo "podman is required for the optional release smoke check" >&2; exit 1; }
task_container="cftunnel-release-smoke-$$"
task_image="localhost/cftunnel-release-smoke:latest"
task_candidate_dir=""
task_mounts=()
cleanup_smoke() {
	podman stop --time 10 "$task_container" >/dev/null 2>&1 || true
	if [[ -n "$task_candidate_dir" ]]; then rm -rf -- "$task_candidate_dir"; fi
}
trap cleanup_smoke EXIT

if [[ "${1:-}" == --candidate && $# -eq 1 ]]; then
	source "$PROJECT_DIR/lib/tui-runtime.sh"
	verify_cftunnel_runtime "$PROJECT_DIR" "$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
	case "$(uname -m)" in x86_64 | amd64) task_arch=x64 ;; aarch64 | arm64) task_arch=arm64 ;; *) exit 1 ;; esac
	task_candidate_dir="$(mktemp -d /tmp/cftunnel-smoke-candidate.XXXXXX)"
	# Only package application files; do not mount the checkout, home, or secrets.
	tar -czf "$task_candidate_dir/cftunnel-linux-$task_arch.tar.gz" --transform='s,^,cf-tunnels/,' -C "$PROJECT_DIR" \
		run.sh install.sh uninstall.sh VERSION lib packages/tui/package.json \
		packages/tui/dist/cftunnel-runtime packages/tui/dist/cftunnel-runtime.manifest.json
	(cd "$task_candidate_dir" && sha256sum "cftunnel-linux-$task_arch.tar.gz") > "$task_candidate_dir/cftunnel-linux-$task_arch.tar.gz.sha256"
	cp "$PROJECT_DIR/install-cftunnel.sh" "$task_candidate_dir/install-cftunnel.sh"
	# The container's non-root user needs read/traverse access to this public bundle.
	chmod 755 "$task_candidate_dir"
	task_mounts=(--volume "$task_candidate_dir:/opt/cftunnel-candidate:ro")
elif [[ $# -ne 0 ]]; then
	echo "Usage: bash tests/release-smoke.sh [--candidate]" >&2
	exit 1
fi

podman build --file "$PROJECT_DIR/tests/release-smoke/Containerfile" --tag "$task_image" "$PROJECT_DIR/tests/release-smoke"
podman run --detach --rm --name "$task_container" --systemd=always \
	--volume "$PROJECT_DIR/tests/release-smoke/check.sh:/opt/cftunnel-smoke-check.sh:ro" "${task_mounts[@]}" "$task_image" >/dev/null
for attempt in {1..30}; do
	if podman exec "$task_container" systemctl is-system-running 2>/dev/null | grep -Eq '^(running|degraded)$'; then break; fi
	sleep 1
done
podman exec "$task_container" sudo --login --user node bash /opt/cftunnel-smoke-check.sh
