# Cloudflare Tunnels - Full Documentation

> Complete reference for deployment, operations, diagnostics, and architecture of the Cloudflare Tunnel infrastructure on this server.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Initial Setup (One-Time)](#initial-setup-one-time)
4. [Directory Structure & File Layout](#directory-structure--file-layout)
5. [The `cftunnel` CLI Tool](#the-cftunnel-cli-tool)
6. [All Active Tunnels](#all-active-tunnels)
7. [YAML Configuration Reference](#yaml-configuration-reference)
8. [systemd Service Management](#systemd-service-management)
9. [Deploying a New Tunnel (Step-by-Step)](#deploying-a-new-tunnel-step-by-step)
10. [Removing a Tunnel](#removing-a-tunnel)
11. [Operations & Day-to-Day Management](#operations--day-to-day-management)
12. [Monitoring with Netdata](#monitoring-with-netdata)
13. [Cloudflare Access (Zero Trust)](#cloudflare-access-zero-trust)
14. [SSH Tunnel Diagnostics](#ssh-tunnel-diagnostics)
15. [Troubleshooting](#troubleshooting)
16. [Security Notes](#security-notes)

---

## Architecture Overview

```
                    Internet Users
                         |
                 Cloudflare Edge (GRU)
                    (QUIC protocol)
                         |
              +----- cloudflared -----+
              |  (QUIC -> local HTTP) |
              +-----------------------+
                    |         |
     +--------------+---------+---------------+
     |         |         |         |          |
  :8080     :8081     :5678    :19999     :2222
  landing    API       n8n    netdata      SSH
```

**How it works:**

- Multiple local services run on different ports on a single Linux server (WSL2).
- The `cloudflared` daemon establishes outbound-only QUIC connections to Cloudflare's edge network (no inbound firewall ports needed).
- Each tunnel maps one or more public hostnames (subdomains of `testes.lat` or `raincity.digital`) to local service ports.
- Cloudflare handles TLS termination, DDoS protection, and optionally Zero Trust access policies.
- **9 tunnels** are currently configured, each managed as a separate systemd service instance.

### Domains

| Domain | Usage |
|---|---|
| `testes.lat` | Primary domain - all subdomains for services |
| `raincity.digital` | Secondary domain - raincity website |

---

## Prerequisites

| Requirement | Notes |
|---|---|
| `cloudflared` binary | Install: `sudo wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && sudo chmod +x /usr/local/bin/cloudflared` |
| `jq` | Required by the `cftunnel` script for JSON parsing |
| Cloudflare account | With the domain(s) added and active |
| Origin certificate | Generated via `cloudflared tunnel login` (stored at `~/.cloudflared/cert.pem`) |
| systemd | For automatic tunnel lifecycle management |
| `sudo` access | Required for systemd operations |

---

## Initial Setup (One-Time)

### 1. Install cloudflared

```bash
sudo wget -O /usr/local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
sudo chmod +x /usr/local/bin/cloudflared
cloudflared --version
```

### 2. Authenticate with Cloudflare

```bash
cloudflared tunnel login
```

This opens a browser to authenticate with your Cloudflare account. It creates `~/.cloudflared/cert.pem` which is used to create/manage tunnels.

### 3. Create the systemd template unit

Create `/etc/systemd/system/cloudflared@.service`:

```ini
[Unit]
Description=cloudflared (%i)
After=network-online.target
Wants=network-online.target

[Service]
User=rodrigo
WorkingDirectory=/home/rodrigo
ExecStart=/usr/local/bin/cloudflared tunnel --config /home/rodrigo/.cloudflared/%i.yml run
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

**Key:** The `%i` is replaced with the instance name (the tunnel name). So `cloudflared@n8n.service` will load `~/.cloudflared/n8n.yml`.

```bash
sudo systemctl daemon-reload
```

### 4. Set up the shell alias

Add to `~/.zsh/aliases.zsh` (already done):

```bash
alias cftunnel="$HOME/cf-tunnels/run.sh"
```

---

## Directory Structure & File Layout

```
~/.cloudflared/                       # Main Cloudflare config directory
├── cert.pem                          # Origin certificate (from `cloudflared tunnel login`)
├── <UUID>.json                       # Per-tunnel credential files (9 files)
├── ssh-tunnel.yml                    # SSH tunnel config
├── llm-tunnel.yml                    # AI/LLM services tunnel config
├── code-server.yml                   # Code Server tunnel config
├── n8n.yml                           # n8n tunnel config
├── netdata-monitoring.yml            # Netdata tunnel config
├── testes-lat.yml                    # Main app (landing/API/admin) tunnel config
├── raincity.yml                      # raincity.digital tunnel config
├── ble-health.yml                    # BLE Health app tunnel config
├── oracle-server-cronjob.yml         # Oracle Cloud cronjob proxy tunnel config
└── ...

~/cf-tunnels/                         # Management scripts and runtime files
├── run.sh                            # cftunnel CLI tool (229 lines)
├── cf-ssh-diagnose.zsh               # SSH diagnostics script (390 lines)
├── install.sh                        # Installer
├── uninstall.sh                      # Uninstaller
└── README.md                        # User documentation
```

---

## The `cftunnel` CLI Tool

The `cftunnel` tool (or `run.sh`) manages Cloudflare Tunnels with systemd integration.

### Commands

| Command | Description |
|---------|-------------|
| `add` | Create tunnel, YAML config, DNS, and enable systemd |
| `remove` | Delete tunnel, clean files, disable systemd |
| `start` | Enable and start tunnel service |
| `stop` | Disable and stop tunnel service |
| `status` | Show systemd status |
| `logs` | Tail logs via journalctl |
| `list` | List all tunnels with status |

### Flags for `add`

| Flag | Required | Description |
|------|----------|-------------|
| `--hostname` | Yes | FQDN to expose (e.g., `api.testes.lat`) |
| `--type` | Yes | Protocol: `ssh`, `http`, or `tcp` |
| `--service` | Yes | Local service URL |
| `--name` | No | Tunnel name (default: `{domain}-{type}`) |

### Examples

```bash
# HTTP service
./run.sh add --hostname api.testes.lat --type http --service http://localhost:4000

# SSH service
./run.sh add --hostname ssh.testes.lat --type ssh --service ssh://localhost:22

# TCP service (Redis, database, etc.)
./run.sh add --hostname redis.testes.lat --type tcp --service tcp://localhost:6379

# List all tunnels
./run.sh list

# View logs
./run.sh logs --name ssh-testes-lat-ssh

# Remove a tunnel
./run.sh remove --name ssh-testes-lat-ssh
```

---

## All Active Tunnels

### Current Tunnels

| Tunnel Name | Hostname | Service | Type | Status |
|-------------|----------|---------|------|--------|
| raincity-digital | raincity.digital | http://localhost:3000 | HTTP | Active |
| testes-lat | testes.lat | http://localhost:8080 | HTTP | Active |
| ssh-tunnel | ssh.testes.lat | ssh://localhost:22 | SSH | Active |
| n8n | n8n.testes.lat | http://localhost:5678 | HTTP | Active |
| netdata-monitoring | netdata.testes.lat | http://localhost:19999 | HTTP | Active |
| llm-tunnel | llm.testes.lat | http://localhost:4000 | HTTP | Active |
| code-server | code.testes.lat | http://localhost:8081 | HTTP | Active |
| ble-health | ble-health.testes.lat | http://localhost:8082 | HTTP | Active |
| oracle-server-cronjob | oracle.testes.lat | http://localhost:8083 | HTTP | Active |
| redis-testes-lat | redis.testes.lat | tcp://localhost:6379 | TCP | Active |

### Quick Commands

```bash
# List all tunnels with status
cftunnel list

# Check specific tunnel
cftunnel status --name n8n

# View logs
cftunnel logs --name n8n

# Restart a tunnel
sudo systemctl restart cloudflared@n8n
```

---

## YAML Configuration Reference

### Example: testes-lat.yml

```yaml
tunnel: 45295609-1085-4c38-bb28-fe79d8cf0fed
credentials-file: /home/rodrigo/.cloudflared/45295609-1085-4c38-bb28-fe79d8cf0fed.json

protocol: http2
edge-ip-version: 4

originRequest:
  tcpKeepAlive: 30s
  keepAliveTimeout: 2m
  connectTimeout: 10s

ingress:
  - hostname: testes.lat
    service: http://localhost:8080
  - service: http_status:404
```

### Example: redis-testes-lat.yml

```yaml
tunnel: 421d4f3a-2ac3-4e7d-9b29-b0c0fee964cf
credentials-file: /home/rodrigo/.cloudflared/421d4f3a-2ac3-4e7d-9b29-b0c0fee964cf.json

protocol: http2
edge-ip-version: 4

originRequest:
  tcpKeepAlive: 30s
  keepAliveTimeout: 2m

ingress:
  - hostname: redis.testes.lat
    service: tcp://localhost:6379
  - service: http_status:404
```

### Configuration Options

| Option | Type | Description |
|--------|------|-------------|
| `tunnel` | string | UUID of the tunnel |
| `credentials-file` | string | Path to tunnel credentials JSON |
| `protocol` | string | `http2` (default) or `h2mux` |
| `edge-ip-version` | string | `4`, `6`, or `auto` |
| `ingress[].hostname` | string | FQDN to match |
| `ingress[].service` | string | Backend service URL |
| `originRequest.tcpKeepAlive` | duration | TCP keepalive interval |
| `originRequest.keepAliveTimeout` | duration | Connection timeout |
| `originRequest.connectTimeout` | duration | Origin connection timeout |

---

## systemd Service Management

### Service Naming

Each tunnel gets its own systemd service:
- Name: `cloudflared@<tunnel-name>.service`
- Config: `~/.cloudflared/<tunnel-name>.yml`

### All Active Services

```bash
systemctl list-units 'cloudflared@*'
```

### Manual Service Commands

```bash
# Start
sudo systemctl start cloudflared@n8n

# Stop
sudo systemctl stop cloudflared@n8n

# Restart
sudo systemctl restart cloudflared@n8n

# Status
sudo systemctl status cloudflared@n8n

# View logs
sudo journalctl -fu cloudflared@n8n

# View recent logs
sudo journalctl -fu cloudflared@n8n --since "1 hour ago"
```

### Restart All Tunnels

```bash
systemctl list-units 'cloudflared@*' --no-legend | awk '{print $1}' | \
  xargs -I{} sudo systemctl restart {}
```

---

## Deploying a New Tunnel (Step-by-Step)

### 1. Ensure your service is running

```bash
# Example: Start a Node.js API
node server.js &
```

### 2. Create the tunnel

```bash
cftunnel add --hostname api.testes.lat --type http --service http://localhost:3000
```

### 3. Verify it's running

```bash
cftunnel status --name api-testes-lat-http
# or
sudo systemctl status cloudflared@api-testes-lat-http
```

### 4. Check DNS resolution

```bash
dig @1.1.1.1 +short api.testes.lat
# Should return: <uuid>.cfargotunnel.com
```

### 5. Test the endpoint

```bash
curl -I https://api.testes.lat
```

### For TCP Tunnels (Redis, PostgreSQL, etc.)

TCP tunnels require special handling - the client must use `cloudflared access tcp`.

#### On the server:

```bash
cftunnel add --hostname redis.testes.lat --type tcp --service tcp://localhost:6379
```

#### On the client machine:

1. Install cloudflared:
```bash
sudo wget -O /usr/local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
sudo chmod +x /usr/local/bin/cloudflared
```

2. Start the TCP access tunnel:
```bash
cloudflared access tcp --hostname redis.testes.lat --url localhost:6379
```

3. Connect:
```bash
redis-cli -h localhost -p 6379
```

---

## Removing a Tunnel

```bash
cftunnel remove --name <tunnel-name>
```

This will:
1. Stop and disable the systemd service
2. Delete the tunnel from Cloudflare
3. Remove the DNS record
4. Delete the YAML config and credentials

---

## Operations & Day-to-Day Management

### Check Tunnel Status

```bash
cftunnel status --name <tunnel-name>
```

### View Logs in Real-Time

```bash
cftunnel logs --name <tunnel-name>
```

### Restart a Tunnel

```bash
sudo systemctl restart cloudflared@<tunnel-name>
```

### Update a Tunnel Config

1. Edit the YAML file: `~/.cloudflared/<tunnel-name>.yml`
2. Restart the service: `sudo systemctl restart cloudflared@<tunnel-name>`

### Validate Tunnel Configuration

```bash
cloudflared tunnel --config ~/.cloudflared/<tunnel-name>.yml ingress validate
```

### Get Tunnel Info

```bash
cloudflared tunnel info <tunnel-name-or-uuid>
```

---

## Monitoring with Netdata

Netdata is available at `netdata.testes.lat` for monitoring server metrics including cloudflared performance.

### Access Netdata

Visit: https://netdata.testes.lat

### Check cloudflared-specific metrics

1. Open Netdata dashboard
2. Navigate to `cloudflared` section
3. Monitor:
   - Connection status
   - Bandwidth usage
   - Latency
   - Errors

---

## Cloudflare Access (Zero Trust)

Sensitive services should use Cloudflare Access for authentication.

### Create an Access Policy

1. Go to [Cloudflare Zero Trust Dashboard](https://dash.cloudflare.com/)
2. Navigate to **Access** → **Applications**
3. Create a new application for your hostname
4. Configure authentication (Google, GitHub, Okta, etc.)
5. Set policies (who can access, when, from where)

### Current Protected Services

| Service | Access Policy |
|---------|---------------|
| ssh.testes.lat | GitHub + Email restricted |
| netdata.testes.lat | GitHub restricted |

---

## SSH Tunnel Diagnostics

Use the included diagnostic script for SSH tunnels:

```bash
~/cf-tunnels/cf-ssh-diagnose.zsh
```

This script checks:
- cloudflared binary presence and version
- systemd service status
- DNS resolution for SSH tunnel
- Tunnel connectivity
- Common configuration issues

---

## Troubleshooting

### Tunnel Not Connecting

```bash
# Check service status
systemctl status cloudflared@<name>

# View recent logs
sudo journalctl -fu cloudflared@<name> --since "10 minutes ago"

# Validate config
cloudflared tunnel --config ~/.cloudflared/<name>.yml ingress validate
```

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `credentials file not found` | Missing `<UUID>.json` | Re-run `cloudflared tunnel login` |
| `DNS record already exists` | CNAME conflict | Remove existing DNS record in Cloudflare dashboard |
| `connection refused` | Local service not running | Start the service on the target port |
| `502 Bad Gateway` | Service not responding | Check service logs |
| `Authentication required` | Access policy enabled | Configure Cloudflare Access or disable it |

### Check DNS Resolution

```bash
# Using Cloudflare DNS (more reliable)
dig @1.1.1.1 +short api.testes.lat

# Using Google DNS
dig @8.8.8.8 +short api.testes.lat

# Should return: <uuid>.cfargotunnel.com
```

### Reset Everything

```bash
# Stop all tunnels
sudo systemctl stop 'cloudflared@*'

# Start all tunnels
sudo systemctl start 'cloudflared@*'
```

---

## Security Notes

### Protect Sensitive Files

```bash
chmod 600 ~/.cloudflared/cert.pem
chmod 600 ~/.cloudflared/*.json
chmod 600 ~/.cloudflared/*.yml
```

### Best Practices

| Practice | Why |
|----------|-----|
| Use Cloudflare Access | Adds authentication layer |
| Keep cert.pem secure | It's your authentication |
| Use HTTPS internally | Encrypt local traffic |
| Monitor logs | Detect unusual access |
| Regular updates | Get latest security patches |

### No Inbound Ports Needed

Cloudflare Tunnels use outbound-only connections:
- Your server initiates the connection to Cloudflare
- No firewall rules needed for inbound traffic
- Traffic flows through Cloudflare's edge

---

## License

MIT License - See [LICENSE](../LICENSE) for details.
