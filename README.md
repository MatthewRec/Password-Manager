# Vaultwarden on Proxmox

A self-hosted password manager: Vaultwarden in Docker on a Proxmox VM, published through a
Cloudflare Tunnel, with **no open ports and no port-forward anywhere on the network**.
Works with the official Bitwarden extensions in Chrome, Edge, Brave, and Safari, syncs
across every signed-in device, and supports multiple user accounts whose vaults are
cryptographically segregated from one another.

Read Steps 0–8 for how to build it.

---

## Why Vaultwarden and not a password manager written from scratch

The requirement was four things: local to a Proxmox server, browser extensions across four
browsers, cross-device sync, and segregated multi-user accounts. Vaultwarden delivers all
four, and does so with cryptography that has been audited and clients that have been
attacked in the wild for years.

Writing a password manager from scratch means writing its cryptography. That is the one
category of software where original work is a liability rather than a credential a subtle
error in key derivation or IV reuse is invisible in testing and total in effect.

So the engineering moved off the vault and onto the infrastructure around it: VM isolation,
a network path with zero inbound exposure, a documented threat model, hardening decisions
with stated rationale, and a backup whose restore has actually been rehearsed. That is the
part worth defending in a review, and it is what this repo contains.

## Architecture

```
Internet ──> Cloudflare edge ──(outbound-only tunnel)──> cloudflared container
                                                              │ internal docker network
                                                              ▼   (no host route)
                                                    vaultwarden container
                                                              │
                                                        ./vw-data
                                                              │
                                        Debian VM on Proxmox ─┴─> nightly encrypted backup
                                                                  shipped off-box
```

Three decisions carry the design:

1. **Docker in a dedicated Debian VM** not on the Proxmox host, not in an LXC container.
   Installing Docker on the hypervisor contaminates it; Docker-in-LXC needs nesting plus
   keyctl and breaks in unobvious ways on upgrade. A VM gives a clean blast radius and lets
   you snapshot the entire vault host before every change.

2. **Vaultwarden publishes no host port.** It sits on an `internal: true` Docker network
   that only `cloudflared` can reach. No port-forward, no inbound firewall rule, nothing
   listening on the LAN. `cloudflared` dials *out* to Cloudflare. Step 8 verifies this
   rather than assuming it.

3. **Cloudflare Access guards `/admin` only.** Putting SSO in front of the whole hostname
   is the most common way people break this setup the Bitwarden extensions and mobile
   apps cannot complete an interactive login challenge, so `/api`, `/identity`, and
   `/notifications` must stay reachable. Only the admin panel gets the SSO wrapper.

**On the Cloudflare trust boundary, stated plainly:** Cloudflare terminates TLS and sees
your request metadata which accounts sync, when, from where. It does **not** see your
secrets. Vault items are encrypted on your device under a key derived from your master
password, which never leaves it. Cloudflare and the server both handle ciphertext only.
If that metadata exposure is unacceptable, swap the tunnel for WireGuard or Tailscale;
everything else in this repo is unchanged.

### Safari, at no cost

Safari support is often the reason self-hosted password managers stop at three browsers,
because a custom Safari extension needs Xcode and a paid Apple Developer account. That does
not apply here. Per Bitwarden's documentation, *"The Safari browser extension is packaged
with the desktop app, available for download from the macOS App Store."* It is free and
needs no developer account. All four browsers are covered with zero client-side work.
(One caveat: account switching in the extension is unsupported on Safari.)

---

## Step 0 Repository

On your workstation:

```powershell
winget install --id Git.Git -e
git init
git add .
git commit -m "Vaultwarden homelab stack"
```

Push to a **private** repo. `.gitignore` already excludes `.env`, `vw-data/`, and every
backup artifact but confirm `git status` is clean of secrets before the first push, not
after. `preflight.sh` checks this too.

## Step 1 Provision the VM on Proxmox

Debian 13 (or 12), **2 vCPU / 2GB RAM / 20GB disk** generous; Vaultwarden idles around
10MB of RAM.

```bash
sudo apt update && sudo apt install -y qemu-guest-agent sqlite3 age rsync curl ufw
sudo systemctl enable --now qemu-guest-agent
```

Give it a static IP or a DHCP reservation, then harden the VM itself:

```bash
# SSH keys only
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh

# Default-deny inbound. Nothing needs to reach this box except your SSH.
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from <your-lan-subnet> to any port 22 proto tcp
sudo ufw enable

sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

**Take a Proxmox snapshot now**, before Docker exists. It is your clean rollback point.

## Step 2 Docker and the stack

Install Docker Engine from Docker's own apt repository not Debian's `docker.io`, which
lags badly:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
```

Clone this repo to `/opt/vaultwarden`, then build your `.env`:

```bash
cp .env.example .env
chmod 600 .env
```

Generate the admin token as an **Argon2 hash**, not plaintext a plaintext token is
readable through `docker inspect` and any read of `.env`:

```bash
docker run --rm -it vaultwarden/server:1.34.3 /vaultwarden hash
```

Paste the whole `$argon2id$v=19$...` string into `ADMIN_TOKEN`, **single-quoted**, or
Compose will try to expand the `$` signs.

Fill in `DOMAIN` (https, no trailing slash), `TUNNEL_TOKEN` (Step 3), and the SMTP block
if you want invitations and email 2FA.

## Step 3 Cloudflare

1. Zero Trust → **Networks → Tunnels → Create a tunnel** (Cloudflared). Copy the token
   into `TUNNEL_TOKEN` in `.env`.
2. **Public hostname**: `vault.yourdomain.com` → Service `HTTP` → `vaultwarden:80`.
   That hostname resolves over the internal Docker network it is the container name,
   not a DNS record you create.
3. **Access application scoped to `/admin*` only.** Application path `vault.yourdomain.com/admin`,
   policy = your email. Do **not** scope it to the whole hostname; that breaks every client.
4. **WAF rate-limiting rule on `/identity/connect/token`** this is the master-password
   brute-force path and the highest-value rule you will write here. Something like 10
   requests per minute per IP, block for 10 minutes.

## Step 4 Bring it up and create accounts

```bash
./preflight.sh          # changes nothing; resolve every FAIL before continuing
docker compose up -d
docker compose ps       # both containers, vaultwarden healthy
```

### 4.1 Register your account
Temporarily set `SIGNUPS_ALLOWED=true` in `.env`, `docker compose up -d`, register at
`https://vault.yourdomain.com`, then **set it straight back to `false`** and
`docker compose up -d` again. This is the control that enforces "no one else can create an
account" `preflight.sh` warns whenever it is left on.

### 4.2 Add your other users
From `/admin` (behind Cloudflare Access), invite by email. Each user sets their own master
password, which you never see and cannot recover.

### 4.3 Harden each account
In every account's **Settings → Security → Keys**:
- Change KDF to **Argon2id** (Vaultwarden defaults to PBKDF2 for compatibility). Memory-hard,
  and far costlier to attack offline.
- Enable **TOTP two-step login**.
- Set a vault timeout and "lock on browser restart".

### 4.4 Verify segregation empirically

Don't assert it demonstrate it. As a second user's data sits in the same SQLite file:

```bash
sqlite3 vw-data/db.sqlite3 \
  "SELECT u.email, substr(c.data,1,60) FROM ciphers c JOIN users u ON u.uuid=c.user_uuid;"
```

Every `data` column is opaque base64, including for accounts that are not yours, and there
is no server-side key that decrypts it each user's vault key is wrapped under a key
derived from their own master password. **Screenshot this.** It is the single most
convincing artifact in the repo, because it shows the segregation is cryptographic rather
than a permission check that a bug could bypass.

## Step 5 Clients

**Chrome / Edge / Brave** one Chromium extension covers all three; install from each
browser's store.

**Safari** install **Bitwarden from the Mac App Store**; the extension ships inside the
desktop app. Then Safari → Settings → Extensions → enable Bitwarden.

**In every client, before logging in**: on the login screen, open the settings/gear icon,
choose **Self-hosted environment**, and set the Server URL to `https://vault.yourdomain.com`.
This is the step everyone misses logging in first will fail against bitwarden.com.

Confirm sync by adding an item on one device and watching it appear on another within
seconds. Browser extensions use WebSockets over the main HTTP port; recent Vaultwarden
serves those without the separate `3012` mapping older guides mention.

## Step 6 Backups

```bash
sudo cp systemd/vaultwarden-backup.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vaultwarden-backup.timer
systemctl list-timers vaultwarden-backup
```

Generate an age keypair and put the **public** key in `AGE_RECIPIENT`:

```bash
age-keygen -o ~/.age/vaultwarden.key
```

**Store the private half somewhere that is not this server.** If the only copy of your
decryption key lives on the box you are backing up, you do not have a backup.

What [`backup.sh`](backup.sh) does that a naive script does not:
- Captures the database with `sqlite3 .backup`, **never `cp`**. A live SQLite file copied
  mid-write produces an archive that restores cleanly and is silently corrupt you find
  out during an outage.
- Runs `PRAGMA integrity_check` on the snapshot before archiving it.
- Includes `rsa_key*`, `config.json`, `attachments/`, and `sends/`. **None of these are in
  the database.** Restoring `db.sqlite3` alone logs every device out and loses every file
  attachment a "successful" restore that has quietly lost data.
- Encrypts, checksums, ships off-box, prunes to `BACKUP_RETENTION_DAYS`, and fails loudly
  if the off-box copy fails.

Layer Proxmox VM backups underneath for bare-metal recovery.

## Step 7 Rehearse the restore

The step that separates this from every other homelab writeup. Quarterly, restore the
latest archive onto a throwaway VM and confirm the vault actually decrypts in a real client:

```bash
./restore.sh /path/to/vaultwarden-YYYYMMDD-HHMMSS.tar.gz.age --dry-run   # verifies, changes nothing
./restore.sh /path/to/vaultwarden-YYYYMMDD-HHMMSS.tar.gz.age             # real restore
```

An untested backup is a hypothesis. Record each drill below.

### Restore drill log

| Date | Archive | Result | Notes |
| --- | --- | --- | --- |
| _pending_ | | | Run the first drill within a week of going live |

## Step 8 Verify the security claims

Don't take the architecture section's word for it:

```bash
# 1. Nothing is listening for Vaultwarden on the host
ss -tlnp | grep -E ':(80|8080|3012)\b'      # expect no output

# 2. Reachable from off-network
curl -I https://vault.yourdomain.com/alive  # expect 200, run from cellular

# 3. Admin is gated, the root is not
curl -sI https://vault.yourdomain.com/admin | head -1   # Cloudflare Access challenge

# 4. Registration is closed
#    Open the URL in a private window - "Create account" must be refused.
```

Also confirm your router has **no** port-forward to this VM. If one exists, the entire
network model in §2 of the threat model is void.

## Step 9 Monitoring and updates

`EXTENDED_LOGGING` and `/data/vaultwarden.log` make failed-login bursts greppable:

```bash
grep -i "Username or password is incorrect" vw-data/vaultwarden.log | tail -50
```

Forwarding that to a SIEM is the obvious next increment and is listed as not-yet-implemented
in the threat model.

**Updates**: snapshot the VM first, then bump the pinned tag in `docker-compose.yml`
deliberately and `docker compose up -d`. Do not point a vault at `:latest` with an
auto-updater check the [release notes](https://github.com/dani-garcia/vaultwarden/releases)
for schema changes before each bump.

---

## Files

| File | Purpose |
| --- | --- |
| [`docker-compose.yml`](docker-compose.yml) | The two-service stack. No published ports, by design. |
| [`.env.example`](.env.example) | Every setting, documented, with dummy values. Copy to `.env`. |
| [`preflight.sh`](preflight.sh) | **Start here.** Validates the host, Docker, config, network, and backup prerequisites. Changes nothing. PASS / WARN / FAIL summary. |
| [`backup.sh`](backup.sh) | Consistent, encrypted, off-box nightly backup. |
| [`restore.sh`](restore.sh) | Restore, with a `--dry-run` that verifies an archive without touching the host. |
| [`systemd/`](systemd/) | Timer and unit for the nightly backup. |
| [`THREAT-MODEL.md`](THREAT-MODEL.md) | Assets, trust boundaries, adversaries, residual risk, and what is deliberately not implemented. |

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Client says "server URL invalid" | Self-hosted environment not set, or `DOMAIN` mismatch. It must match the Cloudflare hostname exactly, https, no trailing slash. |
| Extension logs in but never syncs | Cloudflare Access scoped too broadly it must cover `/admin*` only. |
| TOTP codes always rejected | Clock skew on the VM. `timedatectl` `preflight.sh` checks this. |
| Attachments fail to upload | `DOMAIN` is `http://` rather than `https://`. |
| `bad interpreter: /bin/bash^M` | Scripts copied from Windows with CRLF. `.gitattributes` prevents it via git; otherwise `dos2unix *.sh`. |
| Admin panel rejects the token | `ADMIN_TOKEN` not single-quoted in `.env`, so Compose ate the `$` signs. |
