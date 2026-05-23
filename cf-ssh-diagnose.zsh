#!/usr/bin/env zsh
# cf-ssh-diagnose.zsh
# -----------------------------------------------------------------------------
# Diagnóstico completo de Cloudflare Tunnel + SSH (sshd), compatível com:
#  - Servidores COM systemd (systemctl/journalctl)
#  - Servidores SEM systemd (cloudflared rodando via shell/tmux/screen/rc.local)
#
# O script verifica:
#  • Presença de binários essenciais;
#  • Se "cloudflared" está em execução (via systemd OU via pgrep/ps);
#  • Caminho do config.yml do cloudflared (por systemd, pelos argumentos do processo ou locais padrão);
#  • Ingress (hostname → service), validando porta/“ssh://localhost:<porta>”;
#  • Estado do sshd (processo, porta em escuta via ss, config efetiva via "sshd -T");
#  • DNS do hostname (CNAME → cfargotunnel.com quando aplicável);
#  • Informações do túnel (cloudflared tunnel info/list/route dns);
#  • (Opcional) Dump extenso para /tmp/cf_ssh_diag_<timestamp>.log com dados sensíveis REDACTED.
#
# Uso:
#   zsh cf-ssh-diagnose.zsh --host <FQDN> --expected-port <PORTA> --tunnel <NOME|ID> [--dump] [--verbose]
#
# Parâmetros:
#   --host            Hostname público (ex.: ssh.testes.lat)
#   --expected-port   Porta do sshd (ex.: 2222). Se omitir, tenta inferir por "sshd -T" e senão usa 22.
#   --tunnel          Nome ou ID do túnel para comandos "cloudflared tunnel info/route dns"
#   --dump            Gera /tmp/cf_ssh_diag_<timestamp>.log com saídas detalhadas (redact credenciais/tokens)
#   --verbose         Mais verbosidade no stdout
#
# Saída de status: 0 (ok), 2 (falhas críticas)
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
    *) warn "Argumento desconhecido: $1"; shift;;
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
    fail "Binário requerido não encontrado: $b"
    exit 1
  fi
}
has() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [[ $EUID -ne 0 && -x /usr/bin/sudo ]]; then SUDO="sudo"; fi

# ---------- requisitos ----------
need zsh
need grep
need awk
need sed
need ssh
need ss
need cloudflared
has sshd || [[ -x /usr/sbin/sshd ]] || { fail "sshd não encontrado (nem /usr/sbin/sshd)."; exit 1; }

SYS_HAS_SYSTEMD=0
if has systemctl && has journalctl; then
  if systemctl >/dev/null 2>&1; then SYS_HAS_SYSTEMD=1; fi
fi
(( SYS_HAS_SYSTEMD )) && info "Mode: systemd detectado" || info "Mode: sem systemd (fallback pgrep/ps)"

DNS_TOOL=""
if has dig; then DNS_TOOL="dig"
elif has host; then DNS_TOOL="host"
elif has getent; then DNS_TOOL="getent"
fi

dump "cloudflared --version" cloudflared --version || true

# ---------- sshd: detectar porta ----------
detected_ports=()
if has sshd; then
  ssht="$($SUDO sshd -T 2>/dev/null || true)"
  if [[ -n "$ssht" ]]; then
    detected_ports=("${(@f)$(print -r -- "$ssht" | awk '/^port /{print $2}')}")
    dump "sshd -T (resumo)" /bin/sh -c "$SUDO sshd -T | egrep '^(port|authorizedkeysfile|pubkeyauthentication|trustedusercakeys|passwordauthentication|strictmodes) '"
  fi
fi

if [[ -z "$EXPECTED_PORT" ]]; then
  if (( ${#detected_ports[@]} )); then
    EXPECTED_PORT="${detected_ports[1]}"
    info "Porta esperada (inferida): $EXPECTED_PORT"
  else
    EXPECTED_PORT="22"
    warn "Não consegui inferir porta do sshd; assumindo 22. Use --expected-port para definir explicitamente."
  fi
else
  info "Porta esperada (forçada): $EXPECTED_PORT"
fi

# ---------- cloudflared: detectar execução e config ----------
CF_RUNNING=0
CF_CFG=""
CF_PIDS=()
CF_PS_LINES=()

if (( SYS_HAS_SYSTEMD )); then
  if $SUDO systemctl is-active --quiet cloudflared; then
    CF_RUNNING=1
    ok "cloudflared EM EXECUÇÃO (systemd)."
  else
    warn "cloudflared NÃO está ativo no systemd."
  fi
  dump "systemctl status cloudflared" $SUDO systemctl status cloudflared || true
  svc="$($SUDO systemctl cat cloudflared 2>/dev/null || true)"
  dump "systemctl cat cloudflared" /bin/sh -c "$SUDO systemctl cat cloudflared"
  if [[ -n "$svc" ]]; then
    line=$(print -r -- "$svc" | grep -E 'ExecStart=.*cloudflared' | head -n1 || true)
    if [[ "$line" == *"--config"* ]]; then
      CF_CFG=$(print -r -- "$line" | sed -n 's/.*--config[= ]\([^[:space:]]\+\).*/\1/p' | head -n1)
      [[ -r "$CF_CFG" ]] && ok "Config (systemd): $CF_CFG" || warn "Config via systemd extraída mas não legível: $CF_CFG"
    fi
  fi
fi

# Fallback: pgrep/ps (sem systemd ou systemd inativo)
if (( ! CF_RUNNING )); then
  if has pgrep; then
    CF_PIDS=("${(@f)$(pgrep -f -x '.*cloudflared.*' || true)}")
  else
    CF_PIDS=("${(@f)$(ps -eo pid,cmd | grep -E '[c]loudflared' | awk '{print $1}')}")
  fi
  if (( ${#CF_PIDS[@]} )); then
    CF_RUNNING=1
    ok "cloudflared EM EXECUÇÃO (processo): PIDs ${CF_PIDS[*]}"
    CF_PS_LINES=("${(@f)$(ps -fp ${CF_PIDS[1]} 2>/dev/null || true)}")
    dump "ps -fp ${CF_PIDS[1]}" ps -fp ${CF_PIDS[1]} || true
    # tentar extrair --config do cmdline
    CF_CMD=$(ps -o args= -p ${CF_PIDS[1]} 2>/dev/null || true)
    if [[ "$CF_CMD" == *"--config"* ]]; then
      CF_CFG=$(print -r -- "$CF_CMD" | sed -n 's/.*--config[= ]\([^[:space:]]\+\).*/\1/p' | head -n1)
      [[ -r "$CF_CFG" ]] && ok "Config (processo): $CF_CFG" || warn "Config do processo extraída mas não legível: $CF_CFG"
    fi
  else
    fail "cloudflared NÃO está em execução."
  fi
fi

# Se ainda não sabemos o config, tentar locais padrão
if [[ -z "$CF_CFG" ]]; then
  for f in /etc/cloudflared/config.yml /usr/local/etc/cloudflared/config.yml ~/.cloudflared/config.yml; do
    if [[ -r "$f" ]]; then CF_CFG="$f"; ok "Config (padrão): $CF_CFG"; break; fi
  done
fi
if [[ -n "$CF_CFG" ]]; then
  dump "Conteúdo de $CF_CFG (redact)" /bin/sh -c "cat '$CF_CFG'"
else
  warn "Não consegui localizar um config.yml legível do cloudflared."
fi

# ---------- ingress: extrair hostname → service ----------
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
    warn "Não consegui extrair pares hostname/service do ingress (YAML complexo?)."
  fi

  # Se tiver yq, valida ingress oficialmente
  if has yq; then
    dump "yq ingress parse" yq -r '.ingress[] | select(.hostname != null) | "\(.hostname) -> \(.service)"' "$CF_CFG"
  fi

  # cloudflared possui "tunnel ingress validate" em versões recentes
  if cloudflared tunnel ingress --help >/dev/null 2>&1; then
    info "Validando ingress via cloudflared (se suportado)..."
    dump "cloudflared tunnel ingress validate" cloudflared tunnel ingress validate --config "$CF_CFG" || true
  fi
fi

# ---------- sshd: processo e porta ----------
# Processo
if pgrep -f -x '.*sshd.*' >/dev/null 2>&1 || ps -eo comm | grep -q '[s]shd'; then
  ok "sshd está em execução."
else
  fail "sshd NÃO está em execução."
fi
# Porta
listen_line="$(ss -lntp 2>/dev/null | grep -E ":${EXPECTED_PORT}\b" || true)"
dump "ss -lntp" ss -lntp
if [[ -n "$listen_line" ]]; then
  ok "sshd escutando na porta ${EXPECTED_PORT}."
else
  fail "Porta ${EXPECTED_PORT} NÃO encontrada em escuta (ss)."
fi

# ---------- DNS do hostname ----------
if [[ -n "$HOSTNAME_ARG" ]]; then
  info "DNS do hostname: $HOSTNAME_ARG"
  case "$DNS_TOOL" in
    dig)
      cname="$(dig +short CNAME "$HOSTNAME_ARG" 2>/dev/null | tr -d '\r')"
      arec="$(dig +short A "$HOSTNAME_ARG" 2>/dev/null | tr -d '\r')"
      dump "dig ANY $HOSTNAME_ARG" /bin/sh -c "dig +nocmd $HOSTNAME_ARG any +multiline +noall +answer"
      if [[ -n "$cname" ]]; then
        say "  CNAME: $cname"
        if [[ "$cname" == *".cfargotunnel.com." ]]; then ok "CNAME aponta para cfargotunnel.com (esperado)."
        else warn "CNAME não aponta para cfargotunnel.com"; fi
      elif [[ -n "$arec" ]]; then
        warn "Sem CNAME; há registro A: $arec (não é o padrão de Tunnel)."
      else
        warn "Sem CNAME/A visíveis."
      fi
      ;;
    host)
      dump "host $HOSTNAME_ARG" host "$HOSTNAME_ARG"
      host "$HOSTNAME_ARG" || warn "'host' não conseguiu resolver."
      ;;
    getent)
      dump "getent ahosts $HOSTNAME_ARG" getent ahosts "$HOSTNAME_ARG"
      getent ahosts "$HOSTNAME_ARG" || warn "'getent ahosts' falhou."
      ;;
    *)
      warn "Sem dig/host/getent para checar DNS detalhado."
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
    if [[ -n "$conns" && "$conns" != "0" ]]; then ok "Túnel com conexões ao edge: $conns"
    else fail "Túnel sem conexões (Connections=0)."; fi
    CONNS_STR="$conns"
    if [[ -n "$HOSTNAME_ARG" ]]; then
      if print -r -- "$info_out" | grep -q -F "$HOSTNAME_ARG"; then
        ok "Hostname $HOSTNAME_ARG está associado ao túnel."
      else
        warn "Hostname $HOSTNAME_ARG não apareceu em 'tunnel info'. Verifique 'route dns'."
      fi
    fi
  else
    warn "Não foi possível obter 'tunnel info' (túnel errado? credenciais?)."
  fi

  # Rota DNS (ajuda a vincular o FQDN ao túnel certo)
  if [[ -n "$HOSTNAME_ARG" ]]; then
    dump "cloudflared tunnel route dns (dry-run textual)" /bin/sh -c "echo 'Para associar: cloudflared tunnel route dns $TUNNEL_ARG $HOSTNAME_ARG'"
  fi
else
  warn "Sem --tunnel; pulando checagens de 'tunnel info'."
fi

# ---------- Conectividade local mínima com sshd ----------
# Observação: isso NÃO testa Cloudflare/Access; apenas que a porta local aceita TCP.
if has nc; then
  if nc -z 127.0.0.1 "$EXPECTED_PORT" >/dev/null 2>&1; then
    ok "Teste TCP local: 127.0.0.1:$EXPECTED_PORT acessível."
  else
    warn "Teste TCP local: 127.0.0.1:$EXPECTED_PORT inacessível."
  fi
fi

# ---------- Validação do ingress vs porta esperada ----------
if [[ -n "$HOSTNAME_ARG" && -n "${INGRESS[$HOSTNAME_ARG]:-}" ]]; then
  svc="${INGRESS[$HOSTNAME_ARG]}"
  if [[ "$svc" == ssh://localhost:${EXPECTED_PORT} ]]; then
    ok "Ingress $HOSTNAME_ARG → $svc (porta condiz com sshd)."
  else
    if [[ "$svc" == ssh://localhost:* ]]; then
      warn "Ingress usa ssh://localhost mas porta difere: $svc (esperado :$EXPECTED_PORT)."
    elif [[ "$svc" == tcp://localhost:* ]]; then
      warn "Ingress usa tcp://localhost; funciona, mas recomendo ssh:// para SSH."
    else
      fail "Ingress $HOSTNAME_ARG aponta para $svc (não é ssh://localhost:$EXPECTED_PORT)."
    fi
  fi
elif [[ -n "$HOSTNAME_ARG" ]]; then
  warn "Ingress: hostname $HOSTNAME_ARG não encontrado no $CF_CFG."
fi

# ---------- Resumo ----------
say ""
c "%F{cyan}==== RESUMO ====%f"; say ""
CRIT=0

(( CF_RUNNING )) && ok "cloudflared: em execução" || { fail "cloudflared: NÃO em execução"; CRIT=1; }
# sshd
if pgrep -f -x '.*sshd.*' >/dev/null 2>&1 || ps -eo comm | grep -q '[s]shd'; then
  ok "sshd: em execução"
else
  fail "sshd: NÃO em execução"; CRIT=1
fi
# porta
if ss -lntp | grep -q -E ":${EXPECTED_PORT}\b"; then
  ok "Porta sshd: $EXPECTED_PORT (escutando)"
else
  fail "Porta sshd: $EXPECTED_PORT NÃO encontrada"; CRIT=1
fi
# conexões do túnel
if [[ -n "$CONNS_STR" ]]; then
  if [[ "$CONNS_STR" == "0" ]]; then
    fail "Túnel: Connections=0"; CRIT=1
  else
    ok "Túnel: Connections=$CONNS_STR"
  fi
fi
# dns
if [[ -n "$HOSTNAME_ARG" && -n "${cname:-}" ]]; then
  if [[ "$cname" == *".cfargotunnel.com." ]]; then
    ok "DNS: CNAME → cfargotunnel.com"
  else
    warn "DNS: CNAME não padrão → $cname"
  fi
fi

say ""
if (( DO_DUMP )); then info "Dump salvo em $DUMP_FILE"; fi
if (( CRIT )); then fail "Existem falhas críticas acima."; exit 2; else ok "Diagnóstico concluído."; exit 0; fi
