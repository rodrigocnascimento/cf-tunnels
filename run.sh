#!/usr/bin/env bash
set -euo pipefail

# cftunnel — gerenciador de túneis por subdomínio (modo "um YAML por túnel")
#
# fluxo do comando "add":
#   1. validar flags (hostname, type, service)
#   2. criar túnel Cloudflare (se ainda não existir)
#   3. gerar YAML com ingress rules (hostname → origem local)
#   4. validar ingress via cloudflared
#   5. verificar DNS existente e criar rota CNAME (--no-dns pula esta etapa)
#   6. aguardar propagação DNS e verificar resolução
#   7. habilitar e iniciar serviço systemd (cloudflared@NAME)
#
# uso básico:
#   cftunnel add --hostname ssh.example.com --type ssh --service ssh://localhost:22 --name ssh-config
#   cftunnel add --hostname api.example.com --type http --service http://localhost:4000
#   cftunnel add --hostname redis.example.com --type tcp --service tcp://localhost:6379 --no-dns
#   cftunnel remove --name ssh-config
#   cftunnel start|stop|status|logs --name ssh-config
#   cftunnel list
#
# IMPORTANTE: Para túneis TCP/UDP (Redis, bancos de dados, etc.):
#   1. O túnel é criado no servidor com este script
#   2. Na máquina cliente QUE VAI ACESSAR o serviço, execute:
#      cloudflared access tcp --hostname <HOSTNAME> --url localhost:<PORT>
#   3. Então conecte seu aplicativo em localhost:<PORT> (não no hostname público)
#   4. O tráfego fluirá criptografadamente através do túnel Cloudflare
#
# Exemplo para acesso ao Redis a partir de outra máquina:
#   No servidor: cftunnel add --hostname redis.example.com --type tcp --service tcp://localhost:6379
#   No cliente:  cloudflared access tcp --hostname redis.example.com --url localhost:6379
#   Depois:      redis-cli -h localhost -p 6379

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

# Gera nome seguro para instância systemd a partir do hostname/nome.
# Sanitiza caracteres especiais para que o nome seja válido como unidade systemd
# (apenas [a-z0-9] e hífens, sem hífens no início ou final).
slugify() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

ensure_template() {
	[[ -f "$SYSTEMD_TPL" ]] || die "template systemd não encontrado: $SYSTEMD_TPL
Crie-o conforme combinamos (ExecStart=/usr/local/bin/cloudflared tunnel --config $HOME/.cloudflared/%i.yml run; User=$RUN_USER)."
}

instance_unit() { echo "cloudflared@${1}.service"; }

yaml_path_for() { echo "$BASE_DIR/${1}.yml"; }

json_path_for_uuid() { echo "$BASE_DIR/${1}.json"; }

# Resolve hostname via DNS com fallback em 3 tiers (sem dependências externas):
#   Tier 1: dig @1.1.1.1 (Cloudflare DNS — mostra CNAME, ideal para validar cfargotunnel.com)
#   Tier 2: host           (alternativa com CNAME, mesmo pacote do dig)
#   Tier 3: getent ahosts  (built-in glibc — retorna apenas IP, sem CNAME)
# Se nenhuma ferramenta estiver disponível, retorna string vazia.
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

# Verifica se há ferramenta capaz de consultar registros CNAME (dig ou host).
# getent ahosts só retorna IPs — sem CNAME não é possível validar o padrão cfargotunnel.com.
has_cname_lookup() {
	command -v dig >/dev/null 2>&1 || command -v host >/dev/null 2>&1
}

print_usage() {
	cat <<USAGE
Uso:
  $0 add --hostname FQDN --type (ssh|http|tcp) --service URL [--name NAME] [--no-dns]
  $0 remove --name NAME
  $0 start|stop|status|logs --name NAME
  $0 list

Exemplos:
  $0 add --hostname ssh.example.com  --type ssh  --service ssh://localhost:22  --name ssh-config
  $0 add --hostname api.example.com  --type http --service http://localhost:4000
  $0 add --hostname redis.example.com --type tcp --service tcp://localhost:6379 --no-dns
  $0 logs --name ssh-config
USAGE
}

validate_flags_add() {
	[[ -n "${TUNNEL_HOSTNAME:-}" ]] || die "--hostname é obrigatório"
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

	# Deriva NAME se não informado: usa domínio-base + tipo (ex.: example.com + http → example-com-http)
	local BASE_DOMAIN
	BASE_DOMAIN="$(echo "$TUNNEL_HOSTNAME" | rev | cut -d. -f1-2 | rev)"
	local DEFAULT_NAME
	DEFAULT_NAME="${BASE_DOMAIN}-${TYPE}"
	DEFAULT_NAME="$(echo "$DEFAULT_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/\./-/g')"
	NAME="${NAME:-$DEFAULT_NAME}"
	NAME="$(slugify "$NAME")"
	local UNIT
	UNIT="$(instance_unit "$NAME")"
	local YAML
	YAML="$(yaml_path_for "$NAME")"

	mkdir -p "$BASE_DIR"

	# 1) Criar túnel (se ainda não existir com esse nome)
	if ! $CLOUDFLARED_BIN tunnel list --output json | jq -er ".[] | select(.name==\"$NAME\")" >/dev/null 2>&1; then
		echo "[+] criando túnel: $NAME"
		$CLOUDFLARED_BIN tunnel create "$NAME" >/dev/null
	else
		echo "[=] túnel '$NAME' já existe (ok)"
	fi

	# 2) Capturar UUID e credenciais
	local UUID
	UUID="$($CLOUDFLARED_BIN tunnel list --output json | jq -r ".[] | select(.name==\"$NAME\") | .id")"
	[[ -n "$UUID" && "$UUID" != "null" ]] || die "não consegui obter UUID do túnel '$NAME'"
	local CREDS_JSON="$BASE_DIR/${UUID}.json"
	[[ -f "$CREDS_JSON" ]] || die "credenciais não encontradas: $CREDS_JSON (rode 'cloudflared tunnel login' e re-crie o túnel)"

	# 3) Escrever YAML com:
	#    tunnel:         UUID do túnel Cloudflare
	#    credentials:    chave de autenticação do túnel (arquivo JSON)
	#    protocol:       http2 (recomendado; h2mux é legado)
	#    edge-ip-version: 4 (IPv4 only; use "6" ou "auto" para dual-stack)
	#    originRequest:  timeouts e keepalive da conexão até o serviço local
	#    ingress:        roteamento hostname → serviço local (última regra é o catch-all 404)
	echo "[+] escrevendo YAML: $YAML"
	cat >"$YAML" <<YAML
tunnel: ${UUID}
credentials-file: ${CREDS_JSON}

protocol: "http2"
edge-ip-version: "4"

originRequest:
  tcpKeepAlive: "30s"
  keepAliveTimeout: "2m"
  connectTimeout: "10s"

ingress:
  - hostname: "${TUNNEL_HOSTNAME}"
    service: "${SERVICE}"
  - service: http_status:404
YAML
	chmod 600 "$YAML"

	# 4) Validar ingress
	echo "[+] validando ingress"
	$CLOUDFLARED_BIN tunnel --config "$YAML" ingress validate

	# 5) DNS: verificar existente, criar rota CNAME, aguardar propagação
	if [[ "${NO_DNS:-false}" == true ]]; then
		echo "[=] --no-dns: pulando criação de DNS"
		echo "[=] Crie o registro CNAME manualmente no painel Cloudflare:"
		echo "    ${TUNNEL_HOSTNAME} → ${UUID}.cfargotunnel.com"
	else
		# 5.1) Verificar DNS existente antes de criar rota
		echo "[+] verificando DNS existente para ${TUNNEL_HOSTNAME}..."
		local EXISTING_DNS
		EXISTING_DNS="$(resolve_hostname "$TUNNEL_HOSTNAME")"
		if [[ -n "$EXISTING_DNS" ]]; then
			if has_cname_lookup && [[ "$EXISTING_DNS" == *".cfargotunnel.com"* ]]; then
				echo "[=] DNS já aponta para cfargotunnel (ok)"
			elif ! has_cname_lookup; then
				echo "[=] DNS resolve: $EXISTING_DNS (verificação de CNAME indisponível sem dig/host)"
			else
				echo "[!] AVISO: ${TUNNEL_HOSTNAME} já tem DNS: $EXISTING_DNS"
				echo "[!] Isso pode causar erro 1003 ao criar rota CNAME."
				echo "[!] Recomendação: remova o registro DNS existente (A/CNAME) no painel da Cloudflare antes de continuar."
				read -p "Continuar mesmo assim? (s/N) " -n 1 -r || true
				echo
				if [[ ! "$REPLY" =~ ^[Ss]$ ]]; then
					die "Operação cancelada pelo usuário. Remova o registro DNS e tente novamente."
				fi
			fi
		fi

		# 5.2) Criar/atualizar DNS (CNAME p/ cfargotunnel) - com fail-fast
		echo "[+] criando/atualizando DNS para ${TUNNEL_HOSTNAME}"
		local DNS_OUTPUT
		if ! DNS_OUTPUT="$($CLOUDFLARED_BIN tunnel route dns "$NAME" "$TUNNEL_HOSTNAME" 2>&1)"; then
			echo "[!] erro do cloudflared: $DNS_OUTPUT"
			die "falha ao criar DNS para ${TUNNEL_HOSTNAME}. Verifique: (1) token API configurado? (2) zona está na conta? (3) registro já existe?"
		fi
		echo "$DNS_OUTPUT"

		# 5.3) Validar que DNS foi criado corretamente (aguarda até 30s pela propagação)
		echo "[+] verificando DNS para ${TUNNEL_HOSTNAME}..."
		echo "[!] aguarde até 30s pela propagação (Ctrl+C para pular)..."
		local DNS_RESULT=""
		local WAITED=0
		while [[ -z "$DNS_RESULT" && $WAITED -lt 30 ]]; do
			sleep 5
			DNS_RESULT="$(resolve_hostname "$TUNNEL_HOSTNAME" | head -1 || echo "")"
			WAITED=$((WAITED + 5))
			echo "    [+] tentativa ${WAITED}/30: ${DNS_RESULT:-"nada ainda..."}"
		done

		if [[ -z "$DNS_RESULT" ]]; then
			echo "[!] DNS ainda não resolve após 30s"
			echo "[!] O registro CNAME pode ter sido criado no Cloudflare, mas a propagação leva tempo."
			echo "[!] Você pode verificar no painel: https://dash.cloudflare.com/"
			read -p "Continuar mesmo assim? (s/N) " -n 1 -r || true
			echo
			if [[ ! "$REPLY" =~ ^[Ss]$ ]]; then
				die "Operação cancelada."
			fi
		elif ! has_cname_lookup; then
			echo "[✓] DNS resolve: $DNS_RESULT (verificação de CNAME indisponível sem dig/host)"
		elif [[ "$DNS_RESULT" == *".cfargotunnel.com"* || "$DNS_RESULT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "[✓] DNS OK: $DNS_RESULT"
		else
			echo "[!] aviso: DNS resultado inesperado: $DNS_RESULT"
			echo "[!] esperado: <uuid>.cfargotunnel.com ou IP direto"
		fi
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
	echo "✅ pronto! Túnel '${NAME}' ativo para '${TUNNEL_HOSTNAME}' → ${SERVICE}"
	echo "   - YAML: ${YAML}"
	echo "   - Unit: ${UNIT}"
	echo "   - Logs: sudo journalctl -fu ${UNIT}"
	echo
	# Informação específica para túneis TCP/UDP
	if [[ "$TYPE" == "tcp" || "$TYPE" == "udp" ]]; then
		echo "⚠️  IMPORTANTE: Para túneis TCP/UDP, conecte-se localmente:"
		echo "      Na máquina cliente, execute:"
		echo "      cloudflared access tcp --hostname ${TUNNEL_HOSTNAME} --url localhost:<porta_local>"
		echo "      Então conecte seu aplicativo em localhost:<porta_local>"
	fi
	echo "Dica: se for app protegido, crie a Access Policy p/ ${TUNNEL_HOSTNAME} no Zero Trust (ou automatize via API com CF_API_TOKEN/CF_ACCOUNT_ID)."
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
	$CLOUDFLARED_BIN tunnel delete "$NAME" >/dev/null 2>&1 || true

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
	arr="$($CLOUDFLARED_BIN tunnel list --output json | jq -rc '.[] | [.name,.id] | @tsv')"
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
TUNNEL_HOSTNAME=""
TYPE=""
SERVICE=""
NO_DNS=false

case "${cmd:-}" in
add)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--hostname)
			TUNNEL_HOSTNAME="${2:-}"
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
		--no-dns)
			NO_DNS=true
			shift
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
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		*)
			print_usage
			exit 1
			;;
		esac
	done
	op_start
	;;
stop)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		*)
			print_usage
			exit 1
			;;
		esac
	done
	op_stop
	;;
status)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		*)
			print_usage
			exit 1
			;;
		esac
	done
	op_status
	;;
logs)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			NAME="${2:-}"
			shift 2
			;;
		*)
			print_usage
			exit 1
			;;
		esac
	done
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
