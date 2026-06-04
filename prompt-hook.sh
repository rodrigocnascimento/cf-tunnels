#!/usr/bin/env bash
# cftunnel-prompt-hook.sh
# =============================================================================
# Exports CFTUNNEL_ZONE with the active cftunnel zone name.
# Theme/script authors can use this variable to show the zone in prompts.
#
# Usage: add this line to your ~/.bashrc or ~/.zshrc:
#   source /path/to/cf-tunnels/prompt-hook.sh
# =============================================================================

[[ $- == *i* ]] || return 0

_cftunnel_prompt_refresh() {
	local zone_file="$HOME/.cloudflared/.default_zone"
	if [[ -f "$zone_file" ]]; then
		local z
		z="$(cat "$zone_file" 2>/dev/null | tr -d '\n\r' | head -1)"
		if [[ -n "$z" ]]; then
			CFTUNNEL_ZONE="$z"
		else
			CFTUNNEL_ZONE=""
		fi
	else
		CFTUNNEL_ZONE=""
	fi
}

_cftunnel_prompt_refresh

if [[ -n "${BASH_VERSION:-}" ]]; then
	if [[ -n "${PROMPT_COMMAND:-}" ]]; then
		if [[ "$PROMPT_COMMAND" != *"_cftunnel_prompt_refresh"* ]]; then
			PROMPT_COMMAND="_cftunnel_prompt_refresh; ${PROMPT_COMMAND}"
		fi
	else
		PROMPT_COMMAND="_cftunnel_prompt_refresh"
	fi
fi

if [[ -n "${ZSH_VERSION:-}" ]]; then
	precmd_functions=(${precmd_functions[@]:#_cftunnel_prompt_refresh})
	precmd_functions+=(_cftunnel_prompt_refresh)
fi
