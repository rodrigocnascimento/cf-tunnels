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
└── oracle-server-cronjob.yml         # Oracle Cloud cronjob proxy tunnel config

~/cf-tunnels/                         # Management scripts and runtime files
├── run.sh                            # cftunnel CLI tool (229 lines)
├── cf-ssh-diagnose.zsh               # SSH diagnostics script (390 lines)
├── <name>.pid                        # PID files for running tunnels
└── <name>.log                        # Log files for running tunnels

/etc/systemd/system/
└── cloudflared@.service              # systemd template unit
```

### File naming convention

- **YAML configs:** `~/.cloudflared/<tunnel-name>.yml` - The name matches the systemd instance name
- **Credentials:** `~/.cloudflared/<tunnel-UUID>.json` - Auto-generated when `cloudflared tunnel create` runs
- **Certificate:** `~/.cloudflared/cert.pem` - Shared across all tunnels

---

## The `cftunnel` CLI Tool

**Location:** `~/cf-tunnels/run.sh`  
**Alias:** `cftunnel`

### Commands

| Command | Description | Example |
|---|---|---|
| `add` | Create tunnel, write YAML, validate, set DNS, enable systemd | `cftunnel add --hostname api.testes.lat --type http --service http://localhost:4000` |
| `remove` | Delete tunnel, clean up files, disable systemd | `cftunnel remove --name ssh-tunnel` |
| `start` | Enable and start a tunnel service | `cftunnel start --name n8n` |
| `stop` | Disable and stop a tunnel service | `cftunnel stop --name n8n` |
| `status` | Show systemd status for a tunnel | `cftunnel status --name n8n` |
| `logs` | Tail logs via journalctl | `cftunnel logs --name n8n` |
| `list` | List all tunnels with status | `cftunnel list` |

### `add` flags

| Flag | Required | Description |
|---|---|---|
| `--hostname` | Yes | The FQDN to expose (e.g., `api.testes.lat`) |
| `--type` | Yes | `ssh`, `http`, or `tcp` |
| `--service` | Yes | Local service URL (e.g., `http://localhost:4000`, `ssh://localhost:22`) |
| `--name` | No | Tunnel name (defaults to the first label of hostname) |

### What `add` does internally

1. Creates the tunnel in Cloudflare (`cloudflared tunnel create <name>`)
2. Captures the UUID and verifies credential JSON exists
3. Writes a YAML config to `~/.cloudflared/<name>.yml`
4. Validates the ingress rules (`cloudflared tunnel ingress validate`)
5. Creates/updates DNS CNAME record (`cloudflared tunnel route dns`)
6. Enables and starts the systemd service (`cloudflared@<name>.service`)

---

## All Active Tunnels

### 1. SSH Tunnel

| Field | Value |
|---|---|
| **Name** | `ssh-tunnel` |
| **UUID** | `8b71e74f-2522-402a-9c52-71eb2fcbbd2e` |
| **Config** | `~/.cloudflared/ssh-tunnel.yml` |
| **Hostname** | `ssh.testes.lat` |
| **Service** | `ssh://localhost:2222` |
| **Protocol** | `http2` |
| **Special** | Cloudflare Access required (team: `rodrigolab`) |

### 2. LLM / AI Services Tunnel

| Field | Value |
|---|---|
| **Name** | `llm-tunnel` |
| **UUID** | `b1dfe90f-bd19-4d38-9765-8b4fabcee892` |
| **Config** | `~/.cloudflared/llm-tunnel.yml` |
| **Hostnames** | `ai.testes.lat` -> `:4000`, `webui.testes.lat` -> `:8083`, `ollama.testes.lat` -> `:11434` |
| **Special** | `http2Origin: true` on Ollama endpoint |

### 3. Code Server Tunnel

| Field | Value |
|---|---|
| **Name** | `code-server` |
| **UUID** | `421d4f3a-2ac3-4e7d-9b29-b0c0fee964cf` |
| **Config** | `~/.cloudflared/code-server.yml` |
| **Hostname** | `code.testes.lat` -> `http://localhost:8888` |

### 4. n8n Tunnel

| Field | Value |
|---|---|
| **Name** | `n8n` |
| **UUID** | `7120960d-8a67-416f-8c7e-30d5ee5bb764` |
| **Config** | `~/.cloudflared/n8n.yml` |
| **Hostname** | `n8n.testes.lat` -> `http://localhost:5678` |

### 5. Netdata Monitoring Tunnel

| Field | Value |
|---|---|
| **Name** | `netdata-monitoring` |
| **UUID** | `9b5d0641-0410-4c6d-8ef2-79c25388349f` |
| **Config** | `~/.cloudflared/netdata-monitoring.yml` |
| **Hostname** | `monitoring.testes.lat` -> `http://localhost:19999` |

### 6. Main App Tunnel (testes-lat)

| Field | Value |
|---|---|
| **Name** | `testes-lat` |
| **UUID** | `4eea94a9-a50b-4d20-bbdf-7ff3e923ca84` |
| **Config** | `~/.cloudflared/testes-lat.yml` |
| **Hostnames** | `landingpage.testes.lat` -> `:8080`, `api.testes.lat` -> `:8081`, `admin.testes.lat` -> `:8082` |

### 7. Raincity Digital Tunnel

| Field | Value |
|---|---|
| **Name** | `raincity` |
| **UUID** | `50336d0e-0d9a-496c-8e5c-ec67ce4b42f3` |
| **Config** | `~/.cloudflared/raincity.yml` |
| **Hostname** | `raincity.digital` -> `http://localhost:30000` |

### 8. BLE Health Tunnel

| Field | Value |
|---|---|
| **Name** | `ble-health` |
| **UUID** | `f0e4dbe0-79b4-4a28-b0b8-bfb89beb77c5` |
| **Config** | `~/.cloudflared/ble-health.yml` |
| **Hostname** | `ble-health.testes.lat` -> `http://localhost:8085` |

### 9. Oracle Server Cronjob Tunnel

| Field | Value |
|---|---|
| **Name** | `oracle-server-cronjob` |
| **UUID** | `fc400ce8-b0f9-4e63-94a3-bdbfc0cef25d` |
| **Config** | `~/.cloudflared/oracle-server-cronjob.yml` |
| **Hostname** | `cronjob.testes.lat` -> `http://163.176.235.145:3012` |
| **Special** | Proxies to an external Oracle Cloud server IP (not localhost) |

### Port Map Summary

| Port | Service | Hostname |
|---|---|---|
| 2222 | SSH (sshd) | `ssh.testes.lat` |
| 4000 | AI API | `ai.testes.lat` |
| 5678 | n8n | `n8n.testes.lat` |
| 8080 | Landing Page | `landingpage.testes.lat` |
| 8081 | API Backend | `api.testes.lat` |
| 8082 | Admin Panel | `admin.testes.lat` |
| 8083 | WebUI | `webui.testes.lat` |
| 8085 | BLE Health | `ble-health.testes.lat` |
| 8888 | Code Server | `code.testes.lat` |
| 11434 | Ollama | `ollama.testes.lat` |
| 19999 | Netdata | `monitoring.testes.lat` |
| 30000 | Raincity website | `raincity.digital` |
| 163.176.235.145:3012 | Oracle cronjob | `cronjob.testes.lat` |

---

## YAML Configuration Reference

Each tunnel has a YAML config at `~/.cloudflared/<name>.yml`. Here is the anatomy:

```yaml
# Required: tunnel UUID (from `cloudflared tunnel create`)
tunnel: <UUID>

# Required: path to the credential JSON file
credentials-file: /home/rodrigo/.cloudflared/<UUID>.json

# Optional: connection protocol to Cloudflare edge
protocol: "http2"          # Options: http2, quic (auto-negotiated)

# Optional: force IPv4 connections to edge
edge-ip-version: "4"

# Optional: log verbosity
loglevel: debug            # Options: debug, info, warn, error, fatal

# Optional: global origin request settings
originRequest:
  tcpKeepAlive: "30s"      # TCP keepalive interval
  keepAliveTimeout: "2m"   # Max idle time before closing
  connectTimeout: "10s"    # Connection timeout to origin

# Required: ingress rules (hostname -> service mapping)
ingress:
  - hostname: myapp.testes.lat
    service: http://localhost:8080
    # Optional: per-rule origin overrides
    originRequest:
      http2Origin: true    # Use HTTP/2 to origin
      access:              # Cloudflare Access settings
        required: true
        teamName: rodrigolab

  # REQUIRED: catch-all rule (must be last)
  - service: http_status:404
```

### Service URL formats

| Format | Use Case | Example |
|---|---|---|
| `http://localhost:<port>` | HTTP services | `http://localhost:8080` |
| `https://localhost:<port>` | HTTPS services (origin has TLS) | `https://localhost:443` |
| `ssh://localhost:<port>` | SSH access | `ssh://localhost:2222` |
| `tcp://localhost:<port>` | Raw TCP | `tcp://localhost:6379` |
| `http://<external-ip>:<port>` | Proxy to external host | `http://163.176.235.145:3012` |
| `http_status:<code>` | Return static status code | `http_status:404` (catch-all) |

---

## systemd Service Management

All tunnels use the systemd template unit at `/etc/systemd/system/cloudflared@.service`.

### How the template works

The `%i` placeholder is replaced with the instance name. So:
- `cloudflared@n8n.service` -> loads `~/.cloudflared/n8n.yml`
- `cloudflared@ssh-tunnel.service` -> loads `~/.cloudflared/ssh-tunnel.yml`

### Common systemd commands

```bash
# Start a tunnel
sudo systemctl start cloudflared@<name>

# Stop a tunnel
sudo systemctl stop cloudflared@<name>

# Enable at boot + start now
sudo systemctl enable --now cloudflared@<name>

# Disable at boot + stop now
sudo systemctl disable --now cloudflared@<name>

# Check status
systemctl status cloudflared@<name>

# View logs (follow mode)
sudo journalctl -fu cloudflared@<name>

# View logs since boot
sudo journalctl -b -u cloudflared@<name>

# Reload after changing the template unit file
sudo systemctl daemon-reload

# List all cloudflared instances
systemctl list-units 'cloudflared@*'
```

### Restart behavior

The service is configured with:
- `Restart=always` - Automatically restarts on crash
- `RestartSec=2` - Waits 2 seconds before restarting

---

## Deploying a New Tunnel (Step-by-Step)

### Method 1: Using `cftunnel` (recommended)

```bash
# Simple HTTP service
cftunnel add \
  --hostname myapp.testes.lat \
  --type http \
  --service http://localhost:3000 \
  --name myapp

# SSH service
cftunnel add \
  --hostname myssh.testes.lat \
  --type ssh \
  --service ssh://localhost:22 \
  --name my-ssh

# TCP service (e.g., Redis)
cftunnel add \
  --hostname redis.testes.lat \
  --type tcp \
  --service tcp://localhost:6379 \
  --name redis
```

The tool handles everything: tunnel creation, YAML config, DNS routing, ingress validation, and systemd setup.

### Method 2: Manual deployment

**Step 1: Create the tunnel**

```bash
cloudflared tunnel create myapp
# Output: Created tunnel myapp with id <UUID>
# Creates: ~/.cloudflared/<UUID>.json
```

**Step 2: Write the YAML config**

Create `~/.cloudflared/myapp.yml`:

```yaml
tunnel: <UUID>
credentials-file: /home/rodrigo/.cloudflared/<UUID>.json

protocol: "http2"
edge-ip-version: "4"

originRequest:
  tcpKeepAlive: "30s"
  keepAliveTimeout: "2m"

ingress:
  - hostname: myapp.testes.lat
    service: http://localhost:3000
  - service: http_status:404
```

**Step 3: Validate the ingress**

```bash
cloudflared tunnel --config ~/.cloudflared/myapp.yml ingress validate
```

**Step 4: Create DNS route**

```bash
cloudflared tunnel route dns myapp myapp.testes.lat
```

This creates a CNAME record: `myapp.testes.lat` -> `<UUID>.cfargotunnel.com`

**Step 5: Test manually (optional)**

```bash
cloudflared tunnel --config ~/.cloudflared/myapp.yml run
```

**Step 6: Enable with systemd**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflared@myapp
systemctl status cloudflared@myapp
```

### Multi-hostname tunnel

A single tunnel can serve multiple hostnames. Add multiple ingress rules:

```yaml
ingress:
  - hostname: app.testes.lat
    service: http://localhost:3000
  - hostname: api.testes.lat
    service: http://localhost:4000
  - hostname: ws.testes.lat
    service: http://localhost:5000
  - service: http_status:404
```

Remember to create DNS routes for each hostname:

```bash
cloudflared tunnel route dns myapp app.testes.lat
cloudflared tunnel route dns myapp api.testes.lat
cloudflared tunnel route dns myapp ws.testes.lat
```

---

## Removing a Tunnel

### Method 1: Using `cftunnel`

```bash
cftunnel remove --name myapp
```

This will:
1. Stop and disable the systemd service
2. Delete the tunnel from Cloudflare
3. Remove the YAML config and credential JSON files

### Method 2: Manual removal

```bash
# 1. Stop and disable the service
sudo systemctl disable --now cloudflared@myapp

# 2. Delete the tunnel (also removes DNS routes)
cloudflared tunnel delete myapp

# 3. Clean up local files
rm ~/.cloudflared/myapp.yml
rm ~/.cloudflared/<UUID>.json  # find UUID from the YAML
```

---

## Operations & Day-to-Day Management

### List all tunnels and their status

```bash
cftunnel list
```

Output format:
```
NAME               UUID                                   UP    UNIT                           HOSTNAME -> SERVICE
n8n                7120960d-8a67-416f-8c7e-30d5ee5bb764   yes   cloudflared@n8n.service         n8n.testes.lat -> http://localhost:5678
```

### Check a specific tunnel

```bash
cftunnel status --name n8n
# or
systemctl status cloudflared@n8n
```

### View logs

```bash
cftunnel logs --name n8n
# or
sudo journalctl -fu cloudflared@n8n
```

### Restart a tunnel (after config change)

```bash
sudo systemctl restart cloudflared@n8n
```

### Update cloudflared binary

```bash
sudo cloudflared update
# or manually:
sudo wget -O /usr/local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
sudo chmod +x /usr/local/bin/cloudflared

# Restart all tunnels after update
systemctl list-units 'cloudflared@*' --no-legend | awk '{print $1}' | xargs -I{} sudo systemctl restart {}
```

### Check tunnel connectivity to Cloudflare edge

```bash
cloudflared tunnel info <name-or-uuid>
```

This shows the number of active connections and which Cloudflare edge location they connect to (e.g., GRU = Sao Paulo).

---

## Monitoring with Netdata

External HTTP checks monitor tunnel endpoints from Netdata. Configuration is at `~/netdata-confs/`.

### HTTP Checks (`httpcheck.conf.yaml`)

| Check | URL | Expected Status |
|---|---|---|
| `landing-ext` | `https://landingpage.testes.lat/` | 200, 301, 302 |
| `api-ext` | `https://api.testes.lat/health` | 200 |
| `admin-ext` | `https://admin.testes.lat/` | 200, 301, 302 |

### Alert Rules (`ext-alerts.conf`)

| Alert | Condition | Severity |
|---|---|---|
| `ext_api_latency` | API avg latency > 300ms | warn |
| `ext_api_latency` | API avg latency > 800ms | crit |
| `ext_api_status` | API returns non-200 | warn |
| `ext_landing_latency` | Landing avg latency > 400ms | warn |
| `ext_landing_latency` | Landing avg latency > 1s | crit |
| `ext_landing_status` | Landing returns unexpected status | warn |

---

## Cloudflare Access (Zero Trust)

The SSH tunnel is protected by Cloudflare Access.

### Configuration in `ssh-tunnel.yml`

```yaml
originRequest:
  access:
    required: true
    teamName: rodrigolab
    audTag:
      - 8753c9fa...
```

### How it works

1. Users navigate to `ssh.testes.lat` or use `cloudflared access` to connect.
2. Cloudflare Access checks the user against the configured access policy (set in the Cloudflare Zero Trust dashboard).
3. Only authenticated users in the `rodrigolab` team can reach the SSH service.

### CF Access Service Token

A service token for programmatic access exists at:
`~/cloud-flare-token-service-continue.dev`

This is used for IDE integrations (continue.dev) that need API access through the tunnel without browser-based auth.

### Connecting via SSH through the tunnel

On the **client side**, configure `~/.ssh/config`:

```ssh-config
Host ssh.testes.lat
    ProxyCommand cloudflared access ssh --hostname %h
    User rodrigo
```

Then simply:

```bash
ssh ssh.testes.lat
```

---

## SSH Tunnel Diagnostics

A comprehensive diagnostic tool exists at `~/cf-tunnels/cf-ssh-diagnose.zsh` (390 lines).

### Usage

```bash
zsh ~/cf-tunnels/cf-ssh-diagnose.zsh \
  --host ssh.testes.lat \
  --expected-port 2222 \
  --tunnel ssh-tunnel \
  --dump \
  --verbose
```

### Flags

| Flag | Description |
|---|---|
| `--host <FQDN>` | The public hostname (e.g., `ssh.testes.lat`) |
| `--expected-port <port>` | Expected sshd port (auto-detects if omitted) |
| `--tunnel <name\|UUID>` | Tunnel name or UUID for `cloudflared tunnel info` |
| `--dump` | Save detailed output to `/tmp/cf_ssh_diag_<timestamp>.log` (credentials redacted) |
| `--verbose` | More verbose stdout output |

### What it checks

1. **cloudflared running** - via systemd or pgrep fallback
2. **Config file detection** - from systemd unit, process args, or default paths
3. **Ingress parsing** - validates hostname-to-service mapping
4. **sshd process** - running and listening on expected port
5. **DNS resolution** - CNAME pointing to `cfargotunnel.com`
6. **Tunnel connections** - active connections to Cloudflare edge
7. **Local TCP connectivity** - `nc -z 127.0.0.1:<port>`
8. **Ingress vs port match** - validates the YAML service matches the actual sshd port

### Exit codes

| Code | Meaning |
|---|---|
| 0 | All checks passed |
| 2 | Critical failures detected |

---

## Troubleshooting

### Tunnel not connecting

```bash
# Check if the service is running
systemctl status cloudflared@<name>

# Check logs for errors
sudo journalctl -fu cloudflared@<name> --since "5 minutes ago"

# Validate the config
cloudflared tunnel --config ~/.cloudflared/<name>.yml ingress validate

# Test manually
cloudflared tunnel --config ~/.cloudflared/<name>.yml run
```

### Common errors

| Error | Cause | Fix |
|---|---|---|
| `credentials file not found` | Missing `<UUID>.json` | Re-run `cloudflared tunnel login` then `cloudflared tunnel create` |
| `ingress rule validation failed` | Bad YAML or missing catch-all | Ensure last rule is `- service: http_status:404` |
| `connection refused` | Local service not running on target port | Start the service on the correct port |
| `502 Bad Gateway` | Service running but not responding properly | Check the service logs, verify the correct port |
| `DNS record not found` | CNAME not created | Run `cloudflared tunnel route dns <name> <hostname>` |
| `tunnel already exists` | Name collision | Use a different name or `cloudflared tunnel delete <name>` first |

### Verify DNS is correct

```bash
dig +short CNAME myapp.testes.lat
# Should return: <UUID>.cfargotunnel.com.
```

### Check which tunnels are running

```bash
systemctl list-units 'cloudflared@*' --type=service
```

### Restart all tunnels

```bash
systemctl list-units 'cloudflared@*' --no-legend | awk '{print $1}' | \
  xargs -I{} sudo systemctl restart {}
```

### Check cloudflared version

```bash
cloudflared --version
```

---

## Security Notes

1. **No inbound ports needed.** Tunnels use outbound-only connections. No firewall rules to manage.

2. **Credentials are sensitive.** The files `~/.cloudflared/cert.pem` and `~/.cloudflared/<UUID>.json` grant access to your tunnels. Protect them:
   ```bash
   chmod 600 ~/.cloudflared/cert.pem
   chmod 600 ~/.cloudflared/*.json
   ```

3. **Use Cloudflare Access** for sensitive services (SSH, admin panels). Configure access policies in the Cloudflare Zero Trust dashboard.

4. **The `cert.pem` is the master key.** It can create/delete any tunnel on your account. Keep it safe. You can delete it after creating all tunnels if you only need the per-tunnel credential JSONs to run them.

5. **Service tokens** (like `cloud-flare-token-service-continue.dev`) should be rotated periodically and stored securely.

6. **The Oracle tunnel** (`oracle-server-cronjob.yml`) proxies to an external IP (`163.176.235.145:3012`), not localhost. This means traffic flows: Internet -> Cloudflare -> this server -> Oracle server. Ensure the Oracle server trusts this server.

7. **Log redaction.** The diagnostic script (`cf-ssh-diagnose.zsh`) automatically redacts credentials and tokens in dump files.
