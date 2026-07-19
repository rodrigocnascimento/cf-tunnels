# Setting Up a New Apex Domain

> Complete walkthrough — from domain purchase to live Cloudflare Tunnel.

---

## Prerequisites

| Item | Notes |
|------|-------|
| Cloudflare account | Free plan is sufficient |
| Domain | Bought from any registrar (Namecheap, Porkbun, etc.) |
| Server with `cloudflared` | Debian/Ubuntu recommended |
| `cftunnel` installed | `./install.sh` or symlinked as `cftunnel` |
| `jq` installed | `sudo apt install jq` |
| DNS tools (optional) | `sudo apt install dnsutils` for `dig` |

If you haven't installed `cftunnel` yet:

```bash
git clone <repo-url> ~/cf-tunnels
cd ~/cf-tunnels
./install.sh
```

The installer creates `cftunnel` globally, sets up the systemd template, and
installs the prompt hook.

---

## Step 1 — Add your domain to Cloudflare

1. Log in to [dash.cloudflare.com](https://dash.cloudflare.com/)
2. Click **Add a Site**
3. Enter your apex domain (e.g. `mynewdomain.com`)
4. Select the **Free** plan
5. Cloudflare scans existing DNS records (none for a fresh domain)
6. Click **Continue**

---

## Step 2 — Point nameservers to Cloudflare

Cloudflare displays two nameservers after adding the site:

```
elaine.ns.cloudflare.com
henry.ns.cloudflare.com
```

1. Open your registrar's DNS management page
2. Replace the default registrar nameservers with Cloudflare's
3. Save the change

> ⏱ Nameserver changes can take **minutes to 24 hours** to propagate globally.
> The domain shows **Pending** in Cloudflare's dashboard during propagation.
> Once propagated, it switches to **Active**.

---

## Step 3 — Verify propagation

Check that the domain resolves through Cloudflare:

```bash
dig @1.1.1.1 +short mynewdomain.com
```

If you don't have `dig`, use:

```bash
host mynewdomain.com
# or (built-in, no packages needed)
getent ahosts mynewdomain.com
```

Expected: Cloudflare IP addresses are returned. If nothing resolves, the
nameserver update hasn't propagated yet — wait and retry.

You can also check via Cloudflare's dashboard — the site status changes from
**Pending** to **Active**.

> Once **Active**, you can manage DNS records and create tunnels.

---

## Step 4 — Register the zone with cftunnel

This creates the isolated zone directory and optionally sets it as the
persistent default:

```bash
cftunnel zone use mynewdomain.com
```

Output:

```
✅ Default zone set to 'mynewdomain.com'.
```

This creates `~/.cloudflared/zones/mynewdomain.com/` and saves
`mynewdomain.com` into `~/.cloudflared/.default_zone`.

From now on, every `cftunnel` command will use this zone automatically
(unless overridden with `--zone <other-domain>`).

If you prefer to keep an existing domain as your default and only use the
new domain occasionally, skip the `zone use` step and pass `--zone` on every
command:

```bash
cftunnel --zone mynewdomain.com <command>
```

---

## Step 5 — Authenticate the zone

`zone login` authenticates with Cloudflare and stores the certificate inside
the zone's isolated directory instead of the shared root:

```bash
cftunnel zone login
```

This:

1. Opens a browser for Cloudflare OAuth
2. Generates `~/.cloudflared/cert.pem`
3. Moves it to `~/.cloudflared/zones/mynewdomain.com/cert.pem`

Output:

```
Authenticating with Cloudflare...
✅ Certificate saved to zones/mynewdomain.com/cert.pem
```

> Each zone gets its own `cert.pem`. Tunnels under this zone use this
> certificate automatically — the `cloudflared()` wrapper in the script
> injects `--origincert` pointing to the zone-specific cert.

### Headless servers (SSH-only)

If you can't open a browser on the server, authenticate on a machine that
has one, then copy `cert.pem`:

```bash
# On the machine with a browser:
cloudflared tunnel login
scp ~/.cloudflared/cert.pem your-server:~/

# On the server:
mkdir -p ~/.cloudflared/zones/mynewdomain.com/
mv ~/cert.pem ~/.cloudflared/zones/mynewdomain.com/cert.pem
chmod 600 ~/.cloudflared/zones/mynewdomain.com/cert.pem
```

---

## Step 6 — Create a tunnel

Now you create tunnels under the new domain. Each tunnel exposes one subdomain
pointing to a local service.

### HTTP tunnel (web app / API)

```bash
cftunnel add \
  --hostname app.mynewdomain.com \
  --type http \
  --service http://localhost:3000
```

What happens:

1. **Tunnel created** — `cloudflared tunnel create` generates a UUID and credentials
2. **YAML written** — `~/.cloudflared/zones/mynewdomain.com/app-mynewdomain-com-http.yml`
3. **Ingress validated** — `cloudflared tunnel --config … ingress validate`
4. **DNS record created** — CNAME `app.mynewdomain.com` → `<uuid>.cfargotunnel.com`
5. **Propagation check** — Polls DNS up to 30 seconds
6. **Systemd service started** — `cloudflared@mynewdomain.com_app-mynewdomain-com-http.service`

### SSH tunnel

```bash
cftunnel add \
  --hostname ssh.mynewdomain.com \
  --type ssh \
  --service ssh://localhost:22
```

### TCP tunnel (database, Redis, etc.)

```bash
cftunnel add \
  --hostname redis.mynewdomain.com \
  --type tcp \
  --service tcp://localhost:6379
```

> TCP tunnels require the client to run `cloudflared access tcp` to proxy
> the connection locally. See the [README](../README.md#tcp-tunnels-redis-databases-etc) for details.

### Skip automatic DNS (when DNS is managed externally)

```bash
cftunnel add \
  --hostname app.mynewdomain.com \
  --type http \
  --service http://localhost:3000 \
  --no-dns
```

You must create the CNAME record manually pointing to `<uuid>.cfargotunnel.com`.

---

## Step 7 — Verify everything

### List hostname routes under the zone

```bash
cftunnel list
```

Expected output shows every locally configured ingress hostname in the active zone:

```
ZONE             NAME                    HOSTNAME                   STATUS  SERVICE
mynewdomain.com  mynewdomain-com-http    app.mynewdomain.com       active  http
mynewdomain.com  mynewdomain-com-ssh     ssh.mynewdomain.com       active  ssh
```

### Check systemd status

```bash
sudo systemctl status 'cloudflared@mynewdomain.com_*'
```

### Verify DNS resolution

```bash
dig @1.1.1.1 +short app.mynewdomain.com
```

Expected: `<uuid>.cfargotunnel.com`

### Test via curl (HTTP tunnels)

```bash
curl -I https://app.mynewdomain.com
```

Expected: `HTTP/2 200` (or your application's response).

### View logs

```bash
cftunnel logs --name app-mynewdomain-com-http
```

---

## Step 8 — Optional: Add more tunnels

Repeat Step 6 for every service you want to expose:

```bash
cftunnel add --hostname portainer.mynewdomain.com --type http --service http://localhost:9000
cftunnel add --hostname grafana.mynewdomain.com   --type http --service http://localhost:3000
cftunnel add --hostname pihole.mynewdomain.com    --type http --service http://localhost:8080
```

Each gets its own tunnel, YAML, and systemd service.

---

## Managing multiple domains

If you already have an active zone (`homelaberson.space`) and want to use
the new domain in parallel:

```bash
# Temporarily use the new domain (no default change)
cftunnel --zone mynewdomain.com add --hostname app.mynewdomain.com --type http --service http://localhost:3000

# Switch default back
cftunnel zone use homelaberson.space

# List tunnels in the other domain
cftunnel --zone mynewdomain.com list
```

### See all zones

```bash
ls ~/.cloudflared/zones/
```

Each directory is a zone you've registered:

```
homelaberson.space/
mynewdomain.com/
```

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---------|-------------|-----|
| `cert.pem not found` | Zone not authenticated | Run `cftunnel --zone mynewdomain.com zone login` |
| `zone not found` | No tunnel yet | Run any `--zone mynewdomain.com` command to create the directory |
| `DNS record already exists` | CNAME from previous attempt | Delete the record in Cloudflare dashboard and retry |
| `cloudflared tunnel list` shows outdated warning | Outdated binary | Run `cftunnel cli-update` |
| Domain still **Pending** in dashboard | Nameservers not propagated | Wait — check with `dig @1.1.1.1 +short mynewdomain.com` |
| Tunnel won't start | Bad config or service not running | `cftunnel logs --name <name>` |
| DNS propagation check fails | `dig` not installed | The script uses 3-tier fallback (`dig` → `host` → `getent`), but DNS verification is best-effort — the tunnel starts regardless |
| `list` shows no hostname routes | Selected zone has no YAML ingress hostnames | Run `cftunnel zone unset` to scan all local zones or use `--zone` |

---

## Complete example from scratch

```bash
# 1. Register the zone
cftunnel zone use mynewdomain.com

# 2. Authenticate
cftunnel zone login

# 3. Create tunnels
cftunnel add --hostname app.mynewdomain.com  --type http  --service http://localhost:3000
cftunnel add --hostname ssh.mynewdomain.com  --type ssh   --service ssh://localhost:22
cftunnel add --hostname api.mynewdomain.com  --type http  --service http://localhost:8080

# 4. Verify
cftunnel list
dig @1.1.1.1 +short app.mynewdomain.com

# 5. Done — all services are live
```

---

## Reference

| Command | Purpose |
|---------|---------|
| `cftunnel zone use <domain>` | Register a zone (creates directory + sets default) |
| `cftunnel zone login` | Authenticate and store cert inside the current zone |
| `cftunnel zone current` | Show the active default zone |
| `cftunnel zone unset` | Clear the default zone |
| `cftunnel --zone <domain> add …` | Add tunnel under a non-default zone |
| `cftunnel add …` | Add tunnel under the default zone |
| `cftunnel list` | List local hostname routes in the active zone, or all zones if none is active |
| `cftunnel cli-update` | Update the `cloudflared` binary |
