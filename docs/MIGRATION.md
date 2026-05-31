# Migration Guide — v0.2.0 → v0.3.0

> **Breaking Change Release**
>
> This version introduces the **Profile System** and **Prompt Hook**. Most existing tunnels will continue to work, but `cftunnel list` behavior changes when a default profile is active.

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

### 1. Profile System (Workspace Isolation)

Organize tunnels by project, client, or environment. Each profile has its own directory under `~/.cloudflared/profiles/<slug>/`.

```bash
# Create tunnels in isolated profiles
cftunnel --profile homelab add --hostname nas.example.com --type http --service http://localhost:5000
cftunnel --profile work add --hostname api.company.com --type http --service http://localhost:3000
```

### 2. Persistent Default Profile

Set a profile as your default so you don't need `--profile` every time:

```bash
cftunnel profile use homelab
cftunnel list              # shows only homelab tunnels
cftunnel add --hostname ... # creates in homelab automatically
```

### 3. Prompt Hook 🚇

Your terminal now shows the active profile, like Python venv's `(venv)`:

```bash
# With p10k:
🚇[homelab] ~/projects

# Without p10k:
🚇[homelab] user@host:~$
```

### 4. Test Suite

43 automated tests. Run them anytime:

```bash
cd tests
./run.sh
```

---

## Breaking Changes

### 1. `cftunnel list` filters by default profile

**Before v0.3.0:**
```bash
cftunnel list  # showed ALL tunnels across the entire account
```

**After v0.3.0:**
```bash
cftunnel profile use homelab
cftunnel list  # shows ONLY tunnels whose YAML exists in ~/.cloudflared/profiles/homelab/
```

**Impact:** If you set a default profile, `list` will appear "empty" for tunnels that exist in Cloudflare but were created without a profile (they live in `~/.cloudflared/`, not `~/.cloudflared/profiles/<slug>/`).

**Fix:** Either:
- `cftunnel profile unset` to clear the default and see all tunnels again
- Or migrate old tunnels into a profile (see below)

### 2. New directory structure

**Before:**
```
~/.cloudflared/
├── cert.pem
├── <uuid>.json
└── <tunnel-name>.yml
```

**After (with profiles):**
```
~/.cloudflared/
├── cert.pem
├── .default_profile          # stores active default profile name
├── <uuid>.json               # tunnels without profile (legacy)
├── <tunnel-name>.yml         # tunnels without profile (legacy)
└── profiles/
    └── homelab/
        ├── <uuid>.json
        ├── <tunnel-name>.yml
        └── profile.json      # metadata (primary domain, etc.)
```

---

## Step-by-Step Migration

### Scenario A: You don't use profiles yet (no default set)

**Nothing changes.** Your existing tunnels in `~/.cloudflared/` continue to work. `list` still shows everything because no default profile is active.

**Recommended:** Start using profiles for *new* tunnels:

```bash
# Create a profile for your next project
cftunnel --profile newproject add --hostname app.example.com --type http --service http://localhost:8080 --persist
```

### Scenario B: You want to migrate existing tunnels into a profile

1. **Create the profile** (don't set as default yet):
   ```bash
   cftunnel --profile homelab add --hostname nas.example.com --type http --service http://localhost:5000
   ```

2. **Move old YAMLs into the profile** (manual, one-time):
   ```bash
   mkdir -p ~/.cloudflared/profiles/homelab
   mv ~/.cloudflared/my-old-tunnel.yml ~/.cloudflared/profiles/homelab/
   mv ~/.cloudflared/<uuid>.json ~/.cloudflared/profiles/homelab/   # move credentials too
   ```

3. **Update systemd unit names** (old → new):
   ```bash
   # Old unit (no profile):
   sudo systemctl stop cloudflared@my-old-tunnel.service
   sudo systemctl disable cloudflared@my-old-tunnel.service
   
   # New unit (with profile):
   sudo systemctl enable --now cloudflared@homelab-my-old-tunnel.service
   ```

4. **Set as default** (optional):
   ```bash
   cftunnel profile use homelab
   ```

### Scenario C: You set a default profile but want to see all tunnels

```bash
# Temporary: override with no profile
cftunnel --profile "" list

# Permanent: clear the default
cftunnel profile unset
```

### Scenario D: Prompt hook not showing / breaking your theme

The installer auto-detected your shell and added the hook. If it breaks your prompt:

```bash
# Check if it was added
grep -n "cftunnel installer" ~/.zshrc ~/.bashrc

# Remove manually (or run ./uninstall.sh which does it automatically)
```

If using a custom theme, set mode to `none` and read `CFTUNNEL_PROFILE` yourself:

```bash
# In your ~/.zshrc, BEFORE sourcing the hook:
export CFTUNNEL_PROMPT_MODE=none
source /path/to/cf-tunnels/prompt-hook.sh
# Then use $CFTUNNEL_PROFILE in your theme
```

---

## Before & After Examples

### Creating a tunnel

**v0.2.0:**
```bash
cftunnel add --hostname nas.example.com --type http --service http://localhost:5000
```

**v0.3.0 (with profile):**
```bash
cftunnel --profile homelab add --hostname nas.example.com --type http --service http://localhost:5000
# OR, if homelab is your default:
cftunnel add --hostname nas.example.com --type http --service http://localhost:5000
```

### Listing tunnels

**v0.2.0:**
```bash
cftunnel list   # all tunnels
```

**v0.3.0:**
```bash
cftunnel list              # tunnels in active profile (or all if no default)
cftunnel --profile work list   # tunnels in specific profile
cftunnel profile unset     # clear default to see all
```

### Removing a tunnel

**v0.2.0:**
```bash
cftunnel remove --name nas-example-com-http
```

**v0.3.0:**
```bash
# If the tunnel was created WITH a profile:
cftunnel --profile homelab remove --name nas-example-com-http

# If the tunnel was created WITHOUT a profile (legacy):
cftunnel remove --name nas-example-com-http
```

---

## Troubleshooting

### "cftunnel list is empty after setting a profile"

You set a default profile, but your old tunnels were created without one. They live in `~/.cloudflared/`, not `~/.cloudflared/profiles/<your-profile>/`.

**Fix:**
```bash
cftunnel profile unset     # clear default, see all tunnels
# OR
cftunnel --profile "" list  # temporary override
```

### "🚇[profile] not showing in my prompt"

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
# Now use $CFTUNNEL_PROFILE in your own theme config
```

### "systemctl status shows wrong unit name after migration"

Profiled tunnels use the naming convention `cloudflared@<profile>-<tunnel>.service`. Old units were `cloudflared@<tunnel>.service`.

```bash
# List all cloudflared units
systemctl list-units 'cloudflared@*'

# Stop old units, start new ones
sudo systemctl stop cloudflared@old-name.service
sudo systemctl enable --now cloudflared@profile-old-name.service
```

### "I get 'No tunnels found in profile X' but I have tunnels"

The tunnels were likely created before profiles existed (or in a different profile). Check where their YAML files are:

```bash
find ~/.cloudflared -name "*.yml"
```

If they're in `~/.cloudflared/` directly (not under `profiles/`), they belong to the "legacy" (no-profile) namespace.

---

## Rollback

If you need to revert to v0.2.0 behavior immediately:

```bash
# 1. Clear any active default profile
cftunnel profile unset

# 2. Remove prompt hook from your shell rc files
./uninstall.sh   # this removes the hook blocks automatically

# 3. (Optional) Move profiled YAMLs back to ~/.cloudflared/
#    Only if you want to abandon profiles entirely:
# mv ~/.cloudflared/profiles/*/ *.yml ~/.cloudflared/ 2>/dev/null || true
```

For a complete code rollback, checkout the v0.2.0 tag (if tagged) or the previous commit.

---

## Questions?

- Open an issue on GitHub
- Check `README.md` and `docs/DOCS.md` for full reference
- Run `cftunnel --help` for quick command reference
