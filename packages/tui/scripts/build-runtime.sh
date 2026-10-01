#!/usr/bin/env bash
set -euo pipefail

TUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$TUI_DIR/../.." && pwd)"
RUNTIME_DIR="$TUI_DIR/dist"
RUNTIME="$RUNTIME_DIR/cftunnel-runtime"
VERSION="$(tr -d '[:space:]' < "$REPO_DIR/VERSION")"
PACKAGE_VERSION="$(jq -r '.version' "$TUI_DIR/package.json")"
[[ -n "$VERSION" && "$PACKAGE_VERSION" == "$VERSION" ]] || {
	echo "TUI package version '$PACKAGE_VERSION' does not match cftunnel '$VERSION'" >&2
	exit 1
}

case "$(uname -s)" in
Linux) PLATFORM="linux" ;;
*) echo "Unsupported runtime platform: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
x86_64 | amd64) ARCH="x64" ;;
aarch64 | arm64) ARCH="arm64" ;;
*) echo "Unsupported runtime architecture: $(uname -m)" >&2; exit 1 ;;
esac
TARGET="${CFTUNNEL_BUILD_TARGET:-bun-$PLATFORM-$ARCH}"
[[ "$TARGET" == "bun-linux-x64" || "$TARGET" == "bun-linux-arm64" ]] || {
	echo "Unsupported Bun build target: $TARGET" >&2
	exit 1
}

mkdir -p "$RUNTIME_DIR"
cd "$TUI_DIR"
bun build --compile --production --minify --target "$TARGET" src/runtime.ts --outfile "$RUNTIME"
chmod 755 "$RUNTIME"
HASH="$(sha256sum "$RUNTIME" | awk '{print $1}')"
jq -n \
	--arg version "$VERSION" \
	--arg platform "linux" \
	--arg arch "${TARGET##*-}" \
	--arg target "$TARGET" \
	--arg hash "$HASH" \
	'{schema_version:1,tui_version:$version,cftunnel_contract_schema:1,platform:$platform,arch:$arch,target:$target,sha256:$hash}' \
	> "$RUNTIME.manifest.json"
chmod 644 "$RUNTIME.manifest.json"
echo "Built $TARGET cftunnel runtime for version $VERSION"
