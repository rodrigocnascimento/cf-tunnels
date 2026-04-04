#!/usr/bin/env bash
set -euo pipefail

# cftunnel — gerenciador de túneis por subdomínio (modo "um YAML por túnel")
# Uso básico:
#   cftunnel add --hostname ssh.testes.lat --type ssh --service ssh://localhost:22 --name ssh-config
#   cftunnel add --hostname api.testes.lat --type http --service http://localhost:4000
#   cftunnel add --hostname redis.testes.lat --type tcp --service tcp://localhost:6379
#   cftunnel remove --name ssh-config
#   cftunnel start|stop|status|logs --name ssh-config
#   cftunnel list
#
# IMPORTANTE: Para túneis TCP/UDP (como Redis, bancos de dados, etc.):
#   1. O túnel é criado no servidor com este script
#   2. Na máquina cliente QUE VAI ACESSAR o serviço, execute:
#      cloudflared access tcp --hostname <SEU-HOSTNAME> --url localhost:<PORTA>
#   3. Então conecte seu aplicativo em localhost:<PORTA> (não no hostname público)
#   4. O tráfego fluirá criptografadamente através do túnel Cloudflare
#
# Exemplo para acesso ao Redis a partir de outra máquina:
#   No servidor: cftunnel add --hostname redis.meudominio.com --type tcp --service tcp://localhost:6379
#   No cliente:  cloudflared access tcp --hostname redis.meudominio.com --url localhost:6379
#   Depois:    redis-cli -h localhost -p 6379

# ===== Config padrão =======================================================
RUN_USER="${RUN_USER:-$USER}"
HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")"
CLOUDFLARED_BIN="$(command -v cloudflared || true)"
BASE_DIR="$HOME_DIR/.cloudflared"
SYSTEMD_TPL="/etc/systemd/system/cloudflared@.service"

# ===== Utilidades ==========================================================
die() {
	echo "erro: $*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "comando obrigatório não encontrado: $1"; }

slugify() {
	# gera um nome seguro p/ instância systemd a partir do hostname ou nome passado
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

ensure_template() {
	# Verifica se o template cloudflared@.service existe
	[[ -f "$SYSTEMD_TPL" ]] || die "template systemd não encontrado: $SYSTEMD_TPL
Crie-o conforme combinamos (ExecStart=/usr/local/bin/cloudflared tunnel --config $HOME/.cloudflared/%i.yml run; User=$RUN_USER)."
}

instance_unit() { echo "cloudflared@${1}.service"; }

yaml_path_for() { echo "$BASE_DIR/${1}.yml"; }

json_path_for_uuid() { echo "$BASE_DIR/${1}.json"; }

print_usage() {
	cat <<USAGE
Uso:
  $0 add --hostname FQDN --type (ssh|http|tcp) --service URL [--name NAME]
  $0 remove --name NAME
  $0 start|stop|status|logs --name NAME
  $0 list

Exemplos:
  $0 add --hostname ssh.testes.lat  --type ssh  --service ssh://localhost:22  --name ssh-config
  $0 add --hostname api.testes.lat  --type http --service http://localhost:4000
  $0 logs --name ssh-config
USAGE
}

validate_flags_add() {
	[[ -n "${HOSTNAME:-}" ]] || die "--hostname é obrigatório"
	[[ -n "${TYPE:-}" ]] || die "--type ssh|http|tcp é obrigatório"
	[[ -n "${SERVICE:-}" ]] || die "--service é obrigatório (ex: ssh://localhost:22, http://localhost:4000, tcp://localhost:6379)"
	case "$TYPE" in
	ssh | http | tcp) : ;;
	*) die "--type inválido: $TYPE (use ssh|http|tcp)" ;;
	esac

	# Validar que TYPE corresponde ao esquema do SERVICE
	case "$TYPE" in
	ssh)
		[[ "$SERVICE" == ssh://* ]] || die "--type ssh requer --service ssh://... (ex: ssh://localhost:22)"
		;;
	http)
		[[ "$SERVICE" == http://* ]] || die "--type http requer --service http://... (ex: http://localhost:4000)"
		;;
	tcp)
		[[ "$SERVICE" == tcp://* ]] || die "--type tcp requer --service tcp://... (ex: tcp://localhost:6379)"
		;;
	esac

	# Ask sudo password upfront to avoid interactive prompts mid-execution
	if [[ $EUID -ne 0 ]]; then
		sudo -v || die "precisa de permissão sudo"
	fi
}

# ===== Operações ===========================================================
op_add() {
	need cloudflared
	need jq
	ensure_template

	validate_flags_add

	# Deriva NAME se não informado: usa domínio-base + tipo (ex.: raincity.digital + http → raincity-digital-http)
	local BASE_DOMAIN
	BASE_DOMAIN="$(echo "$HOSTNAME" | rev | cut -d. -f1-2 | rev)" # raincity.digital
	local DEFAULT_NAME
	DEFAULT_NAME="${BASE_DOMAIN}-${TYPE}"                                                   # raincity.digital-http
	DEFAULT_NAME="$(echo "$DEFAULT_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/\./-/g')" # raincity-digital-http
	NAME="${NAME:-$DEFAULT_NAME}"
	NAME="$(slugify "$NAME")"
	local UNIT
	UNIT="$(instance_unit "$NAME")"
	local YAML
	YAML="$(yaml_path_for "$NAME")"

	mkdir -p "$BASE_DIR"

	# 1) Criar túnel (se ainda não existir com esse nome)
	if ! cloudflared tunnel list --output json | jq -er ".[] | select(.name==\"$NAME\")" >/dev/null 2>&1; then
		echo "[+] criando túnel: $NAME"
		cloudflared tunnel create "$NAME" >/dev/null
	else
		echo "[=] túnel '$NAME' já existe (ok)"
	fi

	# 2) Capturar UUID e credenciais
	local UUID
	UUID="$(cloudflared tunnel list --output json | jq -r ".[] | select(.name==\"$NAME\") | .id")"
	[[ -n "$UUID" && "$UUID" != "null" ]] || die "não consegui obter UUID do túnel '$NAME'"
	local CREDS_JSON="$BASE_DIR/${UUID}.json"
	[[ -f "$CREDS_JSON" ]] || die "credenciais não encontradas: $CREDS_JSON (rode 'cloudflared tunnel login' e re-crie o túnel)"

	# 3) Escrever YAML
	echo "[+] escrevendo YAML: $YAML"
	cat >"$YAML" <<YAML
tunnel: ${UUID}
credentials-file: ${CREDS_JSON}

protocol: "http2"
edge-ip-version: "4"

originRequest:
  tcpKeepAlive: "30s"
  keepAliveTimeout: "2m"

ingress:
  - hostname: ${HOSTNAME}
    service: ${SERVICE}
  - service: http_status:404
YAML

	# 4) Validar ingress
	echo "[+] validando ingress"
	cloudflared tunnel --config "$YAML" ingress validate

	# 4.1) Verificar DNS existente antes de criar rota
	echo "[+] verificando DNS existente para ${HOSTNAME}..."
	local EXISTING_DNS
	EXISTING_DNS="$(dig +short "$HOSTNAME" 2>/dev/null || echo "")"
	if [[ -n "$EXISTING_DNS" ]]; then
		if [[ "$EXISTING_DNS" == *".cfargotunnel.com"* ]]; then
			echo "[=] DNS já aponta para cfargotunnel (ok)"
		else
			echo "[!] AVISO: ${HOSTNAME} já tem DNS: $EXISTING_DNS"
			echo "[!] Isso pode causar erro 1003 ao criar rota CNAME."
			echo "[!] Recomendação: remova o registro DNS existente (A/CNAME) no painel da Cloudflare antes de continuar."
			read -p "Continuar mesmo assim? (s/N) " -n 1 -r || true
			echo
			if [[ ! "$REPLY" =~ ^[Ss]$ ]]; then
				die "Operação cancelada pelo usuário. Remova o registro DNS e tente novamente."
			fi
		fi
	fi

	# 5) Criar/atualizar DNS (CNAME p/ cfargotunnel) - com fail-fast
	echo "[+] criando/atualizando DNS para ${HOSTNAME}"
	local DNS_OUTPUT
	if ! DNS_OUTPUT="$(cloudflared tunnel route dns "$NAME" "$HOSTNAME" 2>&1)"; then
		echo "[!] erro do cloudflared: $DNS_OUTPUT"
		die "falha ao criar DNS para ${HOSTNAME}. Verifique: (1) token API configurado? (2) zona raincity.digital está na conta? (3) registro já existe?"
	fi
	echo "$DNS_OUTPUT"

	# 5.1) Validar que DNS foi criado corretamente
	echo "[+] verificando DNS para ${HOSTNAME}..."
	echo "[!]aguarde até 30s pela propagação (Ctrl+C para pular)..."
	local DNS_RESULT=""
	local WAITED=0
	while [[ -z "$DNS_RESULT" && $WAITED -lt 30 ]]; do
		sleep 5
		# Usando o DNS do Cloudflare (1.1.1.1) para evitar falsos negativos por cache local
		DNS_RESULT="$(dig @1.1.1.1 +short "$HOSTNAME" 2>/dev/null | head -1 || echo "")"
		WAITED=$((WAITED + 5))
		echo "    [+] tentativa ${WAITED}/30: ${DNS_RESULT:-"nada ainda..."}"
	done

	if [[ -z "$DNS_RESULT" ]]; then
		echo "[!] DNS ainda não resolve após 30s"
		echo "[!] O registro CNAME pode ter sido criado no Cloudflare, mas a propagação leva tempo."
		echo "[!] Você pode verificar no painel: https://dash.cloudflare.com/raincity.digital/dns"
		read -p "Continuar mesmo assim? (s/N) " -n 1 -r || true
		echo
		if [[ ! "$REPLY" =~ ^[Ss]$ ]]; then
			die "Operação cancelada."
		fi
	elif [[ ! "$DNS_RESULT" == *".cfargotunnel.com"* && ! "$DNS_RESULT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "[!] aviso: DNS resultado inesperado: $DNS_RESULT"
		echo "[!] esperado: <uuid>.cfargotunnel.com ou IP direto"
	else
		echo "[✓] DNS OK: $DNS_RESULT"
	fi

	# 6) Subir systemd instance
	echo "[+] habilitando e iniciando serviço: $UNIT"
	sudo systemctl daemon-reload
	sudo systemctl enable --now "$UNIT"
	sudo systemctl is-active --quiet "$UNIT" || {
		sudo systemctl status "$UNIT" || true
		die "serviço não ficou ativo"
	}

	echo
	echo "✅ pronto! Túnel '${NAME}' ativo para '${HOSTNAME}' → ${SERVICE}"
	echo "   - YAML: ${YAML}"
	echo "   - Unit: ${UNIT}"
	echo "   - Logs: sudo journalctl -fu ${UNIT}"
	echo
	# Informação específica para túneis TCP/UDP
	if [[ "$TYPE" == "tcp" || "$TYPE" == "udp" ]]; then
		echo "⚠️  IMPORTANTE: Para túneis TCP/UDP, conecte-se localmente:"
		echo "      Na máquina cliente, execute:"
		echo "      cloudflared access tcp --hostname ${HOSTNAME} --url localhost:<porta_local>"
		echo "      Então conecte seu aplicativo em localhost:<porta_local>"
	fi
	echo "Dica: se for app protegido, crie a Access Policy p/ ${HOSTNAME} no Zero Trust (ou automatize via API com CF_API_TOKEN/CF_ACCOUNT_ID)."
}

op_remove() {
	need cloudflared
	ensure_template
	[[ -n "${NAME:-}" ]] || die "--name é obrigatório"
	NAME="$(slugify "$NAME")"

	if [[ $EUID -ne 0 ]]; then
		sudo -v || die "precisa de permissão sudo"
	fi

	local UNIT
	UNIT="$(instance_unit "$NAME")"
	local YAML
	YAML="$(yaml_path_for "$NAME")"

	echo "[+] parando e desabilitando ${UNIT}"
	sudo systemctl disable --now "$UNIT" || true

	# localizar UUID a partir do YAML (se existir)
	local UUID=""
	if [[ -f "$YAML" ]]; then
		UUID="$(grep -E '^tunnel:' "$YAML" | awk '{print $2}')"
	fi

	echo "[+] removendo túnel '${NAME}' (se existir)"
	cloudflared tunnel delete "$NAME" >/dev/null 2>&1 || true

	echo "[+] limpando arquivos locais"
	rm -f "$YAML"
	[[ -n "$UUID" ]] && rm -f "$BASE_DIR/${UUID}.json"

	echo "✅ removido: ${NAME}"
}

op_start() {
	[[ -n "${NAME:-}" ]] || die "--name é obrigatório"
	NAME="$(slugify "$NAME")"
	if [[ $EUID -ne 0 ]]; then sudo -v || die "precisa de permissão sudo"; fi
	sudo systemctl enable --now "$(instance_unit "$NAME")"
}
op_stop() {
	[[ -n "${NAME:-}" ]] || die "--name é obrigatório"
	NAME="$(slugify "$NAME")"
	if [[ $EUID -ne 0 ]]; then sudo -v || die "precisa de permissão sudo"; fi
	sudo systemctl disable --now "$(instance_unit "$NAME")" || true
}
op_status() {
	[[ -n "${NAME:-}" ]] || die "--name é obrigatório"
	NAME="$(slugify "$NAME")"
	if [[ $EUID -ne 0 ]]; then sudo -v || die "precisa de permissão sudo"; fi
	systemctl status "$(instance_unit "$NAME")"
}
op_logs() {
	[[ -n "${NAME:-}" ]] || die "--name é obrigatório"
	NAME="$(slugify "$NAME")"
	if [[ $EUID -ne 0 ]]; then sudo -v || die "precisa de permissão sudo"; fi
	sudo journalctl -fu "$(instance_unit "$NAME")"
}

op_list() {
	need jq
	printf "%-18s %-38s %-5s %-10s %-30s %s\n" "NAME" "UUID" "UP" "SERVICE" "UNIT" "HOSTNAME → SERVICE"
	local arr
	arr="$(cloudflared tunnel list --output json | jq -rc '.[] | [.name,.id] | @tsv')"
	while IFS=$'\t' read -r n id; do
		[[ -z "$n" ]] && continue
		local yml="$BASE_DIR/${n}.yml"
		local up="no" svc_state="inactive" unit="cloudflared@${n}.service" host="-" svc="-"
		if systemctl is-active --quiet "$unit" 2>/dev/null; then
			up="yes"
			svc_state="active"
		elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
			svc_state="enabled"
		fi
		if [[ -f "$yml" ]]; then
			host="$(awk '/hostname:/{print $2; exit}' "$yml" || echo "-")"
			svc="$(awk '/service:/{print $2; exit}' "$yml" || echo "-")"
		fi
		printf "%-18s %-38s %-5s %-10s %-30s %s → %s\n" "$n" "$id" "$up" "$svc_state" "$unit" "$host" "$svc"
	done <<<"$arr"
}

# ===== Parser de argumentos ===============================================
cmd="${1:-}"
shift || true
NAME=""
HOSTNAME=""
TYPE=""
SERVICE=""

case "${cmd:-}" in
add)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--hostname)
			HOSTNAME="${2:-}"
			shift 2
			;;
		--type)
			TYPE="${2:-}"
			shift 2
			;;
		--service)
			SERVICE="${2:-}"
			shift 2
			;;
		--name)
			NAME="${2:-}"
			shift 2
			;;
		-h | --help)
			print_usage
			exit 0
			;;
		*)
			echo "flag desconhecida: $1"
			print_usage
			exit 1
			;;
		esac
	done
	op_add
	;;
remove)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		-h | --help)
			print_usage
			exit 0
			;;
		*)
			echo "flag desconhecida: $1"
			print_usage
			exit 1
			;;
		esac
	done
	op_remove
	;;
start)
	while [[ $# -gt 0 ]]; do case "$1" in --name)
		NAME="${2:-}"
		shift 2
		;;
	*)
		print_usage
		exit 1
		;;
	esac done
	op_start
	;;
stop)
	while [[ $# -gt 0 ]]; do case "$1" in --name)
		NAME="${2:-}"
		shift 2
		;;
	*)
		print_usage
		exit 1
		;;
	esac done
	op_stop
	;;
status)
	while [[ $# -gt 0 ]]; do case "$1" in --name)
		NAME="${2:-}"
		shift 2
		;;
	*)
		print_usage
		exit 1
		;;
	esac done
	op_status
	;;
logs)
	while [[ $# -gt 0 ]]; do case "$1" in --name)
		NAME="${2:-}"
		shift 2
		;;
	*)
		print_usage
		exit 1
		;;
	esac done
	op_logs
	;;
list) op_list ;;
-h | --help | "") print_usage ;;
*)
	echo "comando desconhecido: $cmd"
	print_usage
	exit 1
	;;
esac
