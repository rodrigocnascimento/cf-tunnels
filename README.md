# Cloudflare Tunnel Manager

A CLI tool for managing Cloudflare Tunnels with systemd integration. Deploy, monitor, and manage multiple tunnels with a single command.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)

## Features

- **One-command tunnel creation** - Add new tunnels with `--hostname`, `--type`, and `--service`
- **Automatic DNS management** - Creates CNAME records automatically via `cloudflared tunnel route dns`
- **Systemd integration** - Each tunnel runs as a separate systemd service instance
- **Fail-fast validation** - Validates DNS configuration before activating services
- **Type-safe service definitions** - Validates that `--type` matches `--service` protocol
- **Multi-hostname support** - Serve multiple subdomains from a single tunnel
- **Health checks** - Validates ingress rules before deployment
- **Clean removal** - Removes tunnel, DNS records, and systemd service

## Architecture

```
                         Internet Users
                              |
                     Cloudflare Edge
                        (QUIC/H2)
                              |
                   +---- cloudflared ----+
                   |  (outbound only)   |
                   +--------------------+
                              |
           +------------------+------------------+
           |                  |                  |
       localhost:8080    localhost:3000     localhost:22
          (HTTP)            (HTTP)            (SSH)
```

## Requirements

| Requirement | Description |
|-------------|-------------|
| `cloudflared` | Cloudflare Tunnel binary ([install](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/)) |
| `jq` | JSON parser (`sudo apt install jq`) |
| `systemd` | Service manager (included with most Linux distros) |
| `sudo` | For systemd operations |
| Cloudflare account | With domain(s) added |

## Quick Start

### 1. Install cloudflared

```bash
sudo wget -O /usr/local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
sudo chmod +x /usr/local/bin/cloudflared
```

### 2. Authenticate

```bash
cloudflared tunnel login
```

This opens a browser to authenticate with Cloudflare and creates `~/.cloudflared/cert.pem`.

### 3. Set up systemd template

Create `/etc/systemd/system/cloudflared@.service`:

```ini
[Unit]
Description=cloudflared (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=YOUR_USERNAME
WorkingDirectory=/home/YOUR_USERNAME
ExecStart=/usr/local/bin/cloudflared tunnel --config /home/YOUR_USERNAME/.cloudflared/%i.yml run
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

Replace `YOUR_USERNAME` with your Linux username.

```bash
sudo systemctl daemon-reload
```

### 4. Clone and use

```bash
git clone https://github.com/yourrepo/cf-tunnels.git
cd cf-tunnels
chmod +x run.sh

# Create alias (optional)
alias cftunnel="$PWD/run.sh"
```

## Usage

### Add a new tunnel

```bash
# HTTP service
./run.sh add --hostname api.mydomain.com --type http --service http://localhost:4000

# SSH service
./run.sh add --hostname ssh.mydomain.com --type ssh --service ssh://localhost:22

# TCP service (e.g., Redis, PostgreSQL)
./run.sh add --hostname redis.mydomain.com --type tcp --service tcp://localhost:6379

# With custom name
./run.sh add --hostname app.mydomain.com --type http --service http://localhost:8080 --name myapp
```

### Manage tunnels

```bash
# List all tunnels
./run.sh list

# Start a tunnel
./run.sh start --name myapp

# Stop a tunnel
./run.sh stop --name myapp

# Check status
./run.sh status --name myapp

# View logs
./run.sh logs --name myapp

# Remove a tunnel
./run.sh remove --name myapp
```

## CLI Reference

| Command | Description |
|---------|-------------|
| `add` | Create tunnel, YAML config, DNS, and enable systemd |
| `remove` | Delete tunnel, clean files, disable systemd |
| `start` | Enable and start tunnel service |
| `stop` | Disable and stop tunnel service |
| `status` | Show systemd status |
| `logs` | Tail logs via journalctl |
| `list` | List all tunnels with status |

### `add` flags

| Flag | Required | Description |
|------|----------|-------------|
| `--hostname` | Yes | FQDN to expose (e.g., `api.mydomain.com`) |
| `--type` | Yes | Protocol: `ssh`, `http`, or `tcp` |
| `--service` | Yes | Local service URL |
| `--name` | No | Tunnel name (default: `{domain}-{type}`) |

### `service` URL formats

| Format | Example |
|--------|---------|
| `http://localhost:<port>` | `http://localhost:8080` |
| `https://localhost:<port>` | `https://localhost:443` |
| `ssh://localhost:<port>` | `ssh://localhost:22` |
| `tcp://localhost:<port>` | `tcp://localhost:6379` |
| `http://<external-ip>:<port>` | `http://192.168.1.100:8080` |

## Validation & Safety Features

The CLI includes several safety checks:

1. **Type-Service validation** - Ensures `--type` matches `--service` protocol
2. **DNS pre-check** - Warns if existing DNS records might conflict
3. **Fail-fast DNS** - Aborts if DNS creation fails
4. **DNS propagation check** - Validates DNS resolves correctly after creation
5. **Ingress validation** - Validates YAML before deployment

## Configuration Files

### YAML config location

```
~/.cloudflared/<tunnel-name>.yml
```

### Example YAML

```yaml
tunnel: <UUID>
credentials-file: /home/user/.cloudflared/<UUID>.json

protocol: "http2"
edge-ip-version: "4"

originRequest:
  tcpKeepAlive: "30s"
  keepAliveTimeout: "2m"
  connectTimeout: "10s"

ingress:
  - hostname: app.mydomain.com
    service: http://localhost:8080
  - service: http_status:404
```

## Troubleshooting

### Tunnel not connecting

```bash
# Check service status
systemctl status cloudflared@<name>

# View recent logs
sudo journalctl -fu cloudflared@<name> --since "5 minutes ago"

# Validate config
cloudflared tunnel --config ~/.cloudflared/<name>.yml ingress validate
```

### Common errors

| Error | Cause | Fix |
|-------|-------|-----|
| `credentials file not found` | Missing `<UUID>.json` | Re-run `cloudflared tunnel login` |
| `DNS record already exists` | CNAME conflict | Remove existing DNS record in Cloudflare dashboard |
| `connection refused` | Local service not running | Start the service on the target port |
| `502 Bad Gateway` | Service not responding | Check service logs |

### Check DNS resolution

```bash
dig +short CNAME app.mydomain.com
# Should return: <UUID>.cfargotunnel.com
```

### Check tunnel connections

```bash
cloudflared tunnel info <name-or-uuid>
```

## Systemd Commands

```bash
# Manual service management
sudo systemctl start cloudflared@<name>
sudo systemctl stop cloudflared@<name>
sudo systemctl restart cloudflared@<name>

# View all tunnel services
systemctl list-units 'cloudflared@*'

# Restart all tunnels
systemctl list-units 'cloudflared@*' --no-legend | awk '{print $1}' | \
  xargs -I{} sudo systemctl restart {}
```

## Security Notes

1. **Credentials are sensitive** - Protect `~/.cloudflared/cert.pem` and `~/.cloudflared/*.json`:
   ```bash
   chmod 600 ~/.cloudflared/cert.pem
   chmod 600 ~/.cloudflared/*.json
   ```

2. **Use Cloudflare Access** for sensitive services (SSH, admin panels)

3. **No inbound ports needed** - Tunnels use outbound-only connections

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Pull requests welcome! Please ensure shell scripts pass `bash -n` syntax check.

---

**Note:** Replace `mydomain.com` with your actual Cloudflare-managed domain.
