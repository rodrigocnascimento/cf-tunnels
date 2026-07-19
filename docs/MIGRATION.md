# Migration Guide — v0.2.0 → v0.3.0

> **Breaking Change Release**
>
> This version introduces the **Zone System** and **Prompt Hook**. Most existing tunnels will continue to work, but `cftunnel list` behavior changes when a default zone is active. The previous "Profile" concept has been replaced by "Zone" to better reflect Cloudflare's DNS zone structure.

---

## Table of Contents

- [What's New](#whats-new)
- [Breaking Changes](#breaking-changes)
- [Step-by-Step Migration](#step-by-step-migration)
- [Before & After Examples](#before--after-examples)
- [Troubleshooting](#troubleshooting)
- [Rollback](#rollback)

---

## What's New

### 1. Zone System (Cloudflare Zone Isolation)

Organize tunnels by Cloudflare zone. Each zone has its own directory under `~/.cloudflared/zones/<domain>/` with its own `cert.pem`.

```bash
# Authenticate a zone (saves cert to zone directory)
cftunnel zone login

# Create tunnels in isolated zones
cftunnel --zone homelaberson.space add --hostname nas.homelaberson.space --type http --service http://localhost:5000
cftunnel --zone testes.lat add --hostname app.testes.lat --type http --service http://localhost:3000
```

### 2. Persistent Default Zone

Set a zone as your default so you don't need `--zone` every time:

```bash
cftunnel zone use homelaberson.space
cftunnel list              # shows only homelaberson.space tunnels
cftunnel add --hostname ... # creates in homelaberson.space automatically
```

### 3. Per-Zone Authentication (`zone login`)

Each zone can have its own `cert.pem` — no more DNS records created in the wrong zone:

```bash
cftunnel zone use homelaberson.space
cftunnel zone login        # saves cert to zones/homelaberson.space/cert.pem
```

### 4. Prompt Hook 🚇

Your terminal now shows the active zone, like Python venv's `(venv)`:

```bash
# With p10k:
🚇[homelaberson.space] ~/projects

# Without p10k:
🚇[homelaberson.space] user@host:~$
```

### 5. Test Suite

43+ automated tests. Run them anytime:

```bash
cd tests
./run.sh
```

---

## Breaking Changes

### 1. `--profile` replaced by `--zone`

**Before v0.3.0:**
```bash
cftunnel --profile homelab add ...
cftunnel profile use homelab
```

**After v0.3.0:**
```bash
cftunnel --zone homelaberson.space add ...
cftunnel zone use homelaberson.space
```

### 2. `cftunnel list` filters by default zone

**Before v0.3.0:**
```bash
cftunnel list  # showed ALL tunnels across the entire account
```

**After v0.3.0:**
```bash
cftunnel zone use homelaberson.space
cftunnel list  # shows ONLY tunnels whose YAML exists in ~/.cloudflared/zones/homelaberson.space/
```

**Current behavior (v0.3.2+):** `list` reads local YAML only and prints every
hostname/service ingress route. It does not query the Cloudflare account. With
no default zone, it scans `~/.cloudflared/zones/*/*.yml` across all local zones.
Root-level legacy YAML files are intentionally ignored.

**Impact:** Tunnels that exist only in Cloudflare, or only in legacy root-level
YAML files, are not displayed by `cftunnel list`.

**Fix:** Either:
- `cftunnel zone unset` to clear the default and see all configured zones
- Or migrate old root-level tunnels into a zone (see below)

### 3. New directory structure

**Before:**
```
~/.cloudflared/
├── cert.pem
├── <uuid>.json
└── <tunnel-name>.yml
```

**After (with zones):**
```
~/.cloudflared/
├── cert.pem                      # Fallback cert
├── .default_zone                  # stores active default zone name
├── <uuid>.json                   # tunnels without zone (legacy)
├── <tunnel-name>.yml             # tunnels without zone (legacy)
└── zones/
    └── homelaberson.space/
        ├── cert.pem              # Zone-specific cert
        ├── <uuid>.json
        ├── <tunnel-name>.yml
        └── zone.json             # metadata
```

### 4. `_` is now the zone separator in systemd unit names

Units with zones use underscore instead of hyphen as separator:
- Old (profile): `cloudflared@homelab-nas.service`
- New (zone): `cloudflared@homelaberson-space_nas.service`

---

## Step-by-Step Migration

### Scenario A: You don't use zones yet (no default set)

Existing tunnels in `~/.cloudflared/` continue to run as legacy services, but
`cftunnel list` does not display root-level YAML files. Migrate them into a zone
to include their hostname routes in local listing.

**Recommended:** Start using zones for *new* tunnels:

```bash
# Login and set up a zone
cftunnel zone use homelaberson.space
cftunnel zone login              # authenticates and saves cert

# Create a tunnel in the zone
cftunnel --zone homelaberson.space add --hostname app.homelaberson.space --type http --service http://localhost:8080 --persist
```

### Scenario B: You want to migrate existing tunnels into a zone

1. **Create the zone** (don't set as default yet):
   ```bash
   cftunnel --zone homelaberson.space add --hostname nas.homelaberson.space --type http --service http://localhost:5000
   ```

2. **Move old YAMLs into the zone** (manual, one-time):
   ```bash
   mkdir -p ~/.cloudflared/zones/homelaberson.space
   mv ~/.cloudflared/my-old-tunnel.yml ~/.cloudflared/zones/homelaberson.space/
   mv ~/.cloudflared/<uuid>.json ~/.cloudflared/zones/homelaberson.space/
   ```

3. **Update systemd unit names** (old → new):
   ```bash
   # Old unit (no zone):
   sudo systemctl stop cloudflared@my-old-tunnel.service
   sudo systemctl disable cloudflared@my-old-tunnel.service
   
   # New unit (with zone):
   sudo systemctl enable --now cloudflared@homelaberson-space_my-old-tunnel.service
   ```

4. **Set as default** (optional):
   ```bash
   cftunnel zone use homelaberson.space
   ```

### Scenario C: You set a default zone but want to see all tunnels

```bash
# Permanent: clear the default
cftunnel zone unset
```

### Scenario D: Prompt hook not showing / breaking your theme

The installer auto-detected your shell and added the hook. If it breaks your prompt:

```bash
# Check if it was added
grep -n "cftunnel installer" ~/.zshrc ~/.bashrc

# Remove manually (or run ./uninstall.sh which does it automatically)
```

If using a custom theme, set mode to `none` and read `CFTUNNEL_ZONE` yourself:

```bash
# In your ~/.zshrc, BEFORE sourcing the hook:
export CFTUNNEL_PROMPT_MODE=none
source /path/to/cf-tunnels/prompt-hook.sh
# Then use $CFTUNNEL_ZONE in your theme
```

---

## Before & After Examples

### Creating a tunnel

**v0.2.0:**
```bash
cftunnel add --hostname nas.example.com --type http --service http://localhost:5000
```

**v0.3.0 (with zone):**
```bash
cftunnel --zone homelaberson.space add --hostname nas.homelaberson.space --type http --service http://localhost:5000
# OR, if homelaberson.space is your default:
cftunnel add --hostname nas.homelaberson.space --type http --service http://localhost:5000
```

### Listing tunnels

**v0.2.0:**
```bash
cftunnel list   # all tunnels
```

**v0.3.0:**
```bash
cftunnel list                        # routes in active zone (or all local zones if no default)
cftunnel --zone testes.lat list      # routes in a specific local zone
cftunnel zone unset                  # clear default to list all local zones
```

### Removing a tunnel

**v0.2.0:**
```bash
cftunnel remove --name nas-example-com-http
```

**v0.3.0:**
```bash
# If the tunnel was created WITH a zone:
cftunnel --zone homelaberson.space remove --name nas-homelaberson-space-http

# If the tunnel was created WITHOUT a zone (legacy):
cftunnel remove --name nas-example-com-http
```

---

## Troubleshooting

### "cftunnel list is empty after setting a zone"

The selected zone has no YAML files with hostname ingress rules. Root-level
legacy YAML files are not part of local zone listing.

**Fix:**
```bash
cftunnel zone unset     # clear default, see routes from all local zones
```

### "🚇[zone] not showing in my prompt"

The hook is added by `install.sh`. If you installed before v0.3.0, re-run:

```bash
./install.sh --force
```

Or add manually to `~/.zshrc` or `~/.bashrc`:

```bash
source /path/to/cf-tunnels/prompt-hook.sh
```

### "Prompt hook broke my p10k / oh-my-zsh theme"

The hook auto-detects p10k and uses `POWERLEVEL9K_DIR_PREFIX` instead of touching `PROMPT`. If this still conflicts:

```bash
# Disable all prompt modifications, just export the variable:
export CFTUNNEL_PROMPT_MODE=none
source /path/to/cf-tunnels/prompt-hook.sh
# Now use $CFTUNNEL_ZONE in your own theme config
```

### "systemctl status shows wrong unit name after migration"

Zoned tunnels use the naming convention `cloudflared@<zone-slug>_<tunnel>.service`. Old units were `cloudflared@<tunnel>.service`.

```bash
# List all cloudflared units
systemctl list-units 'cloudflared@*'

# Stop old units, start new ones
sudo systemctl stop cloudflared@old-name.service
sudo systemctl enable --now cloudflared@zone-slug_old-name.service
```

### "I get 'No tunnels found in zone X' but I have tunnels"

The tunnels were likely created before zones existed (or in a different zone). Check where their YAML files are:

```bash
find ~/.cloudflared -name "*.yml"
```

If they're in `~/.cloudflared/` directly (not under `zones/`), they belong to the "legacy" (no-zone) namespace.

---

## Rollback

If you need to revert to v0.2.0 behavior immediately:

```bash
# 1. Clear any active default zone
cftunnel zone unset

# 2. Remove prompt hook from your shell rc files
./uninstall.sh   # this removes the hook blocks automatically
```

For a complete code rollback, checkout the v0.2.0 tag (if tagged) or the previous commit.

---

## Questions?

- Open an issue on GitHub
- Check `README.md` and `docs/DOCS.md` for full reference
- Run `cftunnel --help` for quick command reference
