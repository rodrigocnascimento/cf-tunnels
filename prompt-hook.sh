#!/usr/bin/env bash
# cftunnel-prompt-hook.sh
# =============================================================================
# Shows the active cftunnel profile in your shell prompt — works everywhere.
#
# Usage: add this line to your ~/.bashrc or ~/.zshrc:
#   source /path/to/cf-tunnels/prompt-hook.sh
#
# Behavior:
#   - With p10k loaded      → uses POWERLEVEL9K_DIR_PREFIX (non-destructive)
#   - Without p10k (plain)  → prefixes PS1/PROMPT safely
#   - Always exports CFTUNNEL_PROFILE for themes/scripts to read
#
# Override modes (set BEFORE sourcing):
#   export CFTUNNEL_PROMPT_MODE=auto      # default: detect p10k and adapt
#   export CFTUNNEL_PROMPT_MODE=prefix    # always prefix PS1/PROMPT directly
#   export CFTUNNEL_PROMPT_MODE=none      # only set CFTUNNEL_PROFILE variable
#   export CFTUNNEL_PROMPT_MODE=dir_prefix # force p10k DIR_PREFIX
#   export CFTUNNEL_PROMPT_MODE=dir_suffix # force p10k DIR_SUFFIX
#
# Example prompts with active profile "homelab":
#   🚇[homelab] user@host:~$          (plain bash/zsh)
#   🚇[homelab] ~/projects             (with p10k via DIR_PREFIX)
#   ~/projects 🚇[homelab]               (with p10k via DIR_SUFFIX)
# =============================================================================

# Only run in interactive shells
[[ $- == *i* ]] || return 0

# ── Determine mode ──
CFTUNNEL_PROMPT_MODE="${CFTUNNEL_PROMPT_MODE:-auto}"

# Auto-detect p10k
if [[ "$CFTUNNEL_PROMPT_MODE" == "auto" ]]; then
	if [[ -n "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS:-}" || -n "${POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS:-}" ]]; then
		CFTUNNEL_PROMPT_MODE="dir_prefix"
	else
		CFTUNNEL_PROMPT_MODE="prefix"
	fi
fi

# ── Core: refresh CFTUNNEL_PROFILE variable ──
_cftunnel_prompt_refresh() {
	local profile_file="$HOME/.cloudflared/.default_profile"
	if [[ -f "$profile_file" ]]; then
		local p
		p="$(cat "$profile_file" 2>/dev/null | tr -d '\n\r' | head -1)"
		if [[ -n "$p" ]]; then
			CFTUNNEL_PROFILE="$p"
		else
			CFTUNNEL_PROFILE=""
		fi
	else
		CFTUNNEL_PROFILE=""
	fi
}

# ── p10k integration helpers ──
_cftunnel_p10k_update() {
	local mode="${CFTUNNEL_PROMPT_MODE:-}"
	[[ "$mode" == "dir_prefix" || "$mode" == "dir_suffix" ]] || return 0

	local indicator=""
	if [[ -n "${CFTUNNEL_PROFILE:-}" ]]; then
		indicator="%F{cyan}🚇[${CFTUNNEL_PROFILE}]%f"
	fi

	case "$mode" in
		dir_prefix)
			if [[ -n "$indicator" ]]; then
				POWERLEVEL9K_DIR_PREFIX="${indicator} "
			else
				POWERLEVEL9K_DIR_PREFIX=""
			fi
			;;
		dir_suffix)
			if [[ -n "$indicator" ]]; then
				POWERLEVEL9K_DIR_SUFFIX=" ${indicator}"
			else
				POWERLEVEL9K_DIR_SUFFIX=""
			fi
			;;
	esac
}

# ── Bash support ──
if [[ -n "${BASH_VERSION:-}" ]]; then
	_cftunnel_prompt_hook_bash() {
		_cftunnel_prompt_refresh
		_cftunnel_p10k_update

		# Only touch PS1 if in prefix mode
		if [[ "${CFTUNNEL_PROMPT_MODE:-}" == "prefix" ]]; then
			if [[ -z "${_CFTUNNEL_PS1_ORIGINAL:-}" ]]; then
				_CFTUNNEL_PS1_ORIGINAL="${PS1:-}"
			fi
			if [[ -n "${CFTUNNEL_PROFILE:-}" ]]; then
				PS1="\[\033[36m\]🚇[${CFTUNNEL_PROFILE}]\[\033[0m\] ${_CFTUNNEL_PS1_ORIGINAL}"
			else
				PS1="$_CFTUNNEL_PS1_ORIGINAL"
			fi
		fi
	}

	if [[ -n "${PROMPT_COMMAND:-}" ]]; then
		if [[ "$PROMPT_COMMAND" != *"_cftunnel_prompt_hook_bash"* ]]; then
			PROMPT_COMMAND="_cftunnel_prompt_hook_bash; ${PROMPT_COMMAND}"
		fi
	else
		PROMPT_COMMAND="_cftunnel_prompt_hook_bash"
	fi
fi

# ── Zsh support ──
if [[ -n "${ZSH_VERSION:-}" ]]; then
	_cftunnel_prompt_hook_zsh() {
		_cftunnel_prompt_refresh
		_cftunnel_p10k_update

		# Only touch PROMPT if in prefix mode
		if [[ "${CFTUNNEL_PROMPT_MODE:-}" == "prefix" ]]; then
			if [[ -z "${_CFTUNNEL_PROMPT_ORIGINAL:-}" ]]; then
				_CFTUNNEL_PROMPT_ORIGINAL="${PROMPT:-}"
			fi
			if [[ -n "${CFTUNNEL_PROFILE:-}" ]]; then
				PROMPT="%F{cyan}🚇[${CFTUNNEL_PROFILE}]%f ${_CFTUNNEL_PROMPT_ORIGINAL}"
			else
				PROMPT="$_CFTUNNEL_PROMPT_ORIGINAL"
			fi
		fi
	}

	autoload -Uz add-zsh-hook 2>/dev/null || true
	if command -v add-zsh-hook >/dev/null 2>&1; then
		if ! (add-zsh-hook -L precmd | grep -q "_cftunnel_prompt_hook_zsh" 2>/dev/null); then
			add-zsh-hook precmd _cftunnel_prompt_hook_zsh
		fi
	fi
fi
