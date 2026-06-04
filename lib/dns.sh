[[ -z "${_CFTUNNEL_DNS_LOADED:-}" ]] || return 0
_CFTUNNEL_DNS_LOADED=1

resolve_hostname() {
	local hostname="$1"

	if command -v dig >/dev/null 2>&1; then
		dig @1.1.1.1 +short "$hostname" 2>/dev/null
		return
	fi

	if command -v host >/dev/null 2>&1; then
		host "$hostname" 2>/dev/null | awk '/has address|is an alias/{print $NF}' | head -1
		return
	fi

	if command -v getent >/dev/null 2>&1; then
		getent ahosts "$hostname" 2>/dev/null | awk '{print $1; exit}'
		return
	fi

	echo ""
}

has_cname_lookup() {
	command -v dig >/dev/null 2>&1 || command -v host >/dev/null 2>&1
}
