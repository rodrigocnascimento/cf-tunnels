#!/usr/bin/env zsh
# cf-ssh-diagnose.zsh
# -----------------------------------------------------------------------------
# Complete Cloudflare Tunnel + SSH (sshd) diagnostic, compatible with:
#  - Servers WITH systemd (systemctl/journalctl)
#  - Servers WITHOUT systemd (cloudflared running via shell/tmux/screen/rc.local)
#
# Checks performed:
#  • Presence of essential binaries;
#  • Whether "cloudflared" is running (via systemd OR via pgrep/ps);
#  • cloudflared config.yml path (via systemd, process arguments, or default locations);
#  • Ingress (hostname → service), validating port/"ssh://localhost:<port>";
#  • sshd state (process, listening port via ss, effective config via "sshd -T");
#  • Hostname DNS (CNAME → cfargotunnel.com when applicable);
#  • Tunnel info (cloudflared tunnel info/list/route dns);
#  • (Optional) Extensive dump to /tmp/cf_ssh_diag_<timestamp>.log with sensitive data REDACTED.
#
# Usage:
#   zsh cf-ssh-diagnose.zsh --host <FQDN> --expected-port <PORT> --tunnel <NAME|ID> [--dump] [--verbose]
#
# Parameters:
#   --host            Public hostname (e.g.: ssh.example.com)
#   --expected-port   sshd port (e.g.: 2222). If omitted, tries to infer via "sshd -T", else uses 22.
#   --tunnel          Tunnel name or ID for "cloudflared tunnel info/route dns" commands
#   --dump            Generates /tmp/cf_ssh_diag_<timestamp>.log with detailed output (redacts credentials/tokens)
#   --verbose         More verbosity on stdout
#
# Exit status: 0 (ok), 2 (critical failures)
# -----------------------------------------------------------------------------

set -o errexit
set -o pipefail
set -o nounset

# ---------- UI ----------
autoload -U colors && colors
is_tty=1
[[ -t 1 ]] || is_tty=0
say() { print -r -- "$*"; }
c() { (( is_tty )) && print -nr -- "${(%)1}" || true; }  # color helper
ok()   { c "%F{green}[OK]%f ";   say "$*"; }
warn() { c "%F{yellow}[WARN]%f "; say "$*"; }
fail() { c "%F{red}[FAIL]%f ";   say "$*"; }
info() { c "%F{blue}[INFO]%f ";  say "$*"; }

# ---------- args ----------
HOSTNAME_ARG=""
EXPECTED_PORT=""
TUNNEL_ARG=""
DO_DUMP=0
VERBOSE=0

while (( $# )); do
  case "$1" in
    --host)            HOSTNAME_ARG="${2:-}"; shift 2;;
    --host=*)          HOSTNAME_ARG="${1#--host=}"; shift;;
    --expected-port)   EXPECTED_PORT="${2:-}"; shift 2;;
    --expected-port=*) EXPECTED_PORT="${1#--expected-port=}"; shift;;
    --tunnel)          TUNNEL_ARG="${2:-}"; shift 2;;
    --tunnel=*)        TUNNEL_ARG="${1#--tunnel=}"; shift;;
    --dump)            DO_DUMP=1; shift;;
    --verbose)         VERBOSE=1; shift;;
    -h|--help) sed -n '1,140p' "$0"; exit 0;;
    *) warn "Unknown argument: $1"; shift;;
  esac
done

TS=$(date +%Y%m%d_%H%M%S)
DUMP_FILE="/tmp/cf_ssh_diag_${TS}.log"

redact() {
  sed -E \
    -e 's/(credentials-file:).*/\1 REDACTED/gI' \
		-e 's/(--credentials-file[ =]).*/\1REDACTED/gI' \
    -e 's/(token=|authorization: Bearer )[[:alnum:]_.=-]+/\1REDACTED/gI'
}
dump() {
  (( DO_DUMP )) || return 0
  print -r -- "==== $1 ====" >> "$DUMP_FILE"
  shift || true
  if (( $# )); then
    "$@" 2>&1 | redact >> "$DUMP_FILE"
  else
    cat | redact >> "$DUMP_FILE"
  fi
  print >> "$DUMP_FILE"
}
(( DO_DUMP )) && : > "$DUMP_FILE" && info "Dump → $DUMP_FILE"

# ---------- helpers ----------
need() {
  local b="$1"
  if ! command -v "$b" >/dev/null 2>&1; then
    fail "Required binary not found: $b"
    exit 1
  fi
}
has() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [[ $EUID -ne 0 && -x /usr/bin/sudo ]]; then SUDO="sudo"; fi

# ---------- requirements ----------
need zsh
need grep
need awk
need sed
need ssh
need ss
need cloudflared
has sshd || [[ -x /usr/sbin/sshd ]] || { fail "sshd not found (nor /usr/sbin/sshd)."; exit 1; }

SYS_HAS_SYSTEMD=0
if has systemctl && has journalctl; then
  if systemctl >/dev/null 2>&1; then SYS_HAS_SYSTEMD=1; fi
fi
(( SYS_HAS_SYSTEMD )) && info "Mode: systemd detected" || info "Mode: no systemd (fallback pgrep/ps)"

DNS_TOOL=""
if has dig; then DNS_TOOL="dig"
elif has host; then DNS_TOOL="host"
elif has getent; then DNS_TOOL="getent"
fi

dump "cloudflared --version" cloudflared --version || true

# ---------- sshd: detect port ----------
detected_ports=()
if has sshd; then
  ssht="$($SUDO sshd -T 2>/dev/null || true)"
  if [[ -n "$ssht" ]]; then
    detected_ports=("${(@f)$(print -r -- "$ssht" | awk '/^port /{print $2}')}")
    dump "sshd -T (summary)" /bin/sh -c "$SUDO sshd -T | egrep '^(port|authorizedkeysfile|pubkeyauthentication|trustedusercakeys|passwordauthentication|strictmodes) '"
  fi
fi

if [[ -z "$EXPECTED_PORT" ]]; then
  if (( ${#detected_ports[@]} )); then
    EXPECTED_PORT="${detected_ports[1]}"
    info "Expected port (inferred): $EXPECTED_PORT"
  else
    EXPECTED_PORT="22"
    warn "Could not infer sshd port; assuming 22. Use --expected-port to set explicitly."
  fi
else
  info "Expected port (forced): $EXPECTED_PORT"
fi

# ---------- cloudflared: detect execution and config ----------
CF_RUNNING=0
CF_CFG=""
CF_PIDS=()
CF_PS_LINES=()

if (( SYS_HAS_SYSTEMD )); then
  if $SUDO systemctl is-active --quiet cloudflared; then
    CF_RUNNING=1
    ok "cloudflared RUNNING (systemd)."
  else
    warn "cloudflared NOT active on systemd."
  fi
  dump "systemctl status cloudflared" $SUDO systemctl status cloudflared || true
  svc="$($SUDO systemctl cat cloudflared 2>/dev/null || true)"
  dump "systemctl cat cloudflared" /bin/sh -c "$SUDO systemctl cat cloudflared"
  if [[ -n "$svc" ]]; then
    line=$(print -r -- "$svc" | grep -E 'ExecStart=.*cloudflared' | head -n1 || true)
    if [[ "$line" == *"--config"* ]]; then
      CF_CFG=$(print -r -- "$line" | sed -n 's/.*--config[= ]\([^[:space:]]\+\).*/\1/p' | head -n1)
      [[ -r "$CF_CFG" ]] && ok "Config (systemd): $CF_CFG" || warn "Config extracted from systemd but not readable: $CF_CFG"
    fi
  fi
fi

# Fallback: pgrep/ps (no systemd or systemd inactive)
if (( ! CF_RUNNING )); then
  if has pgrep; then
    CF_PIDS=("${(@f)$(pgrep -f -x '.*cloudflared.*' || true)}")
  else
    CF_PIDS=("${(@f)$(ps -eo pid,cmd | grep -E '[c]loudflared' | awk '{print $1}')}")
  fi
  if (( ${#CF_PIDS[@]} )); then
    CF_RUNNING=1
    ok "cloudflared RUNNING (process): PIDs ${CF_PIDS[*]}"
    CF_PS_LINES=("${(@f)$(ps -fp ${CF_PIDS[1]} 2>/dev/null || true)}")
    dump "ps -fp ${CF_PIDS[1]}" ps -fp ${CF_PIDS[1]} || true
    # try to extract --config from cmdline
    CF_CMD=$(ps -o args= -p ${CF_PIDS[1]} 2>/dev/null || true)
    if [[ "$CF_CMD" == *"--config"* ]]; then
      CF_CFG=$(print -r -- "$CF_CMD" | sed -n 's/.*--config[= ]\([^[:space:]]\+\).*/\1/p' | head -n1)
      [[ -r "$CF_CFG" ]] && ok "Config (process): $CF_CFG" || warn "Config extracted from process but not readable: $CF_CFG"
    fi
  else
    fail "cloudflared is NOT running."
  fi
fi

# If we still don't know the config, try default locations
if [[ -z "$CF_CFG" ]]; then
  for f in /etc/cloudflared/config.yml /usr/local/etc/cloudflared/config.yml ~/.cloudflared/config.yml; do
    if [[ -r "$f" ]]; then CF_CFG="$f"; ok "Config (default): $CF_CFG"; break; fi
  done
fi
if [[ -n "$CF_CFG" ]]; then
  dump "Contents of $CF_CFG (redact)" /bin/sh -c "cat '$CF_CFG'"
else
  warn "Could not locate a readable cloudflared config.yml."
fi

# ---------- ingress: extract hostname → service ----------
typeset -A INGRESS
if [[ -n "$CF_CFG" ]]; then
  local_hostname=""
  while IFS= read -r line; do
    case "$line" in
      (#i)*hostname:*)
        local_hostname="${${line#*hostname: }//[[:space:]]/}"
        ;;
      (#i)*service:*)
        local service="${${line#*service: }//[[:space:]]/}"
        if [[ -n "$local_hostname" && -n "$service" ]]; then
          INGRESS[$local_hostname]="$service"
          local_hostname=""
        fi
        ;;
    esac
  done < "$CF_CFG"

  if (( ${#INGRESS[@]} )); then
    info "Ingress (hostname → service):"; for k v in "${(@kv)INGRESS}"; do say "  - $k  ->  $v"; done
  else
    warn "Could not extract hostname/service pairs from ingress (complex YAML?)."
  fi

  # If yq is available, validate ingress officially
  if has yq; then
    dump "yq ingress parse" yq -r '.ingress[] | select(.hostname != null) | "\(.hostname) -> \(.service)"' "$CF_CFG"
  fi

  # cloudflared has "tunnel ingress validate" in recent versions
  if cloudflared tunnel ingress --help >/dev/null 2>&1; then
    info "Validating ingress via cloudflared (if supported)..."
    dump "cloudflared tunnel ingress validate" cloudflared tunnel ingress validate --config "$CF_CFG" || true
  fi
fi

# ---------- sshd: process and port ----------
if pgrep -f -x '.*sshd.*' >/dev/null 2>&1 || ps -eo comm | grep -q '[s]shd'; then
  ok "sshd is running."
else
  fail "sshd is NOT running."
fi
listen_line="$(ss -lntp 2>/dev/null | grep -E ":${EXPECTED_PORT}\b" || true)"
dump "ss -lntp" ss -lntp
if [[ -n "$listen_line" ]]; then
  ok "sshd listening on port ${EXPECTED_PORT}."
else
  fail "Port ${EXPECTED_PORT} NOT found in listening state (ss)."
fi

# ---------- Hostname DNS ----------
if [[ -n "$HOSTNAME_ARG" ]]; then
  info "Hostname DNS: $HOSTNAME_ARG"
  case "$DNS_TOOL" in
    dig)
      cname="$(dig +short CNAME "$HOSTNAME_ARG" 2>/dev/null | tr -d '\r')"
      arec="$(dig +short A "$HOSTNAME_ARG" 2>/dev/null | tr -d '\r')"
      dump "dig ANY $HOSTNAME_ARG" /bin/sh -c "dig +nocmd $HOSTNAME_ARG any +multiline +noall +answer"
      if [[ -n "$cname" ]]; then
        say "  CNAME: $cname"
        if [[ "$cname" == *".cfargotunnel.com." ]]; then ok "CNAME points to cfargotunnel.com (expected)."
        else warn "CNAME does not point to cfargotunnel.com"; fi
      elif [[ -n "$arec" ]]; then
        warn "No CNAME; A record found: $arec (not the Tunnel standard)."
      else
        warn "No CNAME/A records visible."
      fi
      ;;
    host)
      dump "host $HOSTNAME_ARG" host "$HOSTNAME_ARG"
      host "$HOSTNAME_ARG" || warn "'host' could not resolve."
      ;;
    getent)
      dump "getent ahosts $HOSTNAME_ARG" getent ahosts "$HOSTNAME_ARG"
      getent ahosts "$HOSTNAME_ARG" || warn "'getent ahosts' failed."
      ;;
    *)
      warn "No dig/host/getent to check DNS details."
      ;;
  esac
fi

# ---------- cloudflared tunnel info/list/route ----------
CONNS_STR=""
if [[ -n "$TUNNEL_ARG" ]]; then
  dump "cloudflared tunnel list" cloudflared tunnel list || true
  info_out="$(cloudflared tunnel info "$TUNNEL_ARG" 2>/dev/null || true)"
  dump "cloudflared tunnel info $TUNNEL_ARG" cloudflared tunnel info "$TUNNEL_ARG" || true
  if [[ -n "$info_out" ]]; then
    conns=$(print -r -- "$info_out" | awk '/Connections:/ {print $2; exit}')
    if [[ -n "$conns" && "$conns" != "0" ]]; then ok "Tunnel with edge connections: $conns"
    else fail "Tunnel with no connections (Connections=0)."; fi
    CONNS_STR="$conns"
    if [[ -n "$HOSTNAME_ARG" ]]; then
      if print -r -- "$info_out" | grep -q -F "$HOSTNAME_ARG"; then
        ok "Hostname $HOSTNAME_ARG is associated with the tunnel."
      else
        warn "Hostname $HOSTNAME_ARG did not appear in 'tunnel info'. Check 'route dns'."
      fi
    fi
  else
    warn "Could not obtain 'tunnel info' (wrong tunnel? credentials?)."
  fi

  # DNS route (helps link the FQDN to the correct tunnel)
  if [[ -n "$HOSTNAME_ARG" ]]; then
    dump "cloudflared tunnel route dns (dry-run textual)" /bin/sh -c "echo 'To associate: cloudflared tunnel route dns $TUNNEL_ARG $HOSTNAME_ARG'"
  fi
else
  warn "No --tunnel; skipping 'tunnel info' checks."
fi

# ---------- Minimal local connectivity with sshd ----------
# Note: this does NOT test Cloudflare/Access; only that the local port accepts TCP.
if has nc; then
  if nc -z 127.0.0.1 "$EXPECTED_PORT" >/dev/null 2>&1; then
    ok "Local TCP test: 127.0.0.1:$EXPECTED_PORT reachable."
  else
    warn "Local TCP test: 127.0.0.1:$EXPECTED_PORT unreachable."
  fi
fi

# ---------- Ingress validation vs expected port ----------
if [[ -n "$HOSTNAME_ARG" && -n "${INGRESS[$HOSTNAME_ARG]:-}" ]]; then
  svc="${INGRESS[$HOSTNAME_ARG]}"
  if [[ "$svc" == ssh://localhost:${EXPECTED_PORT} ]]; then
    ok "Ingress $HOSTNAME_ARG → $svc (port matches sshd)."
  else
    if [[ "$svc" == ssh://localhost:* ]]; then
      warn "Ingress uses ssh://localhost but port differs: $svc (expected :$EXPECTED_PORT)."
    elif [[ "$svc" == tcp://localhost:* ]]; then
      warn "Ingress uses tcp://localhost; works, but ssh:// is recommended for SSH."
    else
      fail "Ingress $HOSTNAME_ARG points to $svc (not ssh://localhost:$EXPECTED_PORT)."
    fi
  fi
elif [[ -n "$HOSTNAME_ARG" ]]; then
  warn "Ingress: hostname $HOSTNAME_ARG not found in $CF_CFG."
fi

# ---------- Summary ----------
say ""
c "%F{cyan}==== SUMMARY ====%f"; say ""
CRIT=0

(( CF_RUNNING )) && ok "cloudflared: running" || { fail "cloudflared: NOT running"; CRIT=1; }
if pgrep -f -x '.*sshd.*' >/dev/null 2>&1 || ps -eo comm | grep -q '[s]shd'; then
  ok "sshd: running"
else
  fail "sshd: NOT running"; CRIT=1
fi
if ss -lntp | grep -q -E ":${EXPECTED_PORT}\b"; then
  ok "sshd port: $EXPECTED_PORT (listening)"
else
  fail "sshd port: $EXPECTED_PORT NOT found"; CRIT=1
fi
if [[ -n "$CONNS_STR" ]]; then
  if [[ "$CONNS_STR" == "0" ]]; then
    fail "Tunnel: Connections=0"; CRIT=1
  else
    ok "Tunnel: Connections=$CONNS_STR"
  fi
fi
if [[ -n "$HOSTNAME_ARG" && -n "${cname:-}" ]]; then
  if [[ "$cname" == *".cfargotunnel.com." ]]; then
    ok "DNS: CNAME → cfargotunnel.com"
  else
    warn "DNS: non-standard CNAME → $cname"
  fi
fi

say ""
if (( DO_DUMP )); then info "Dump saved to $DUMP_FILE"; fi
if (( CRIT )); then fail "There are critical failures above."; exit 2; else ok "Diagnostic complete."; exit 0; fi
