# Threat Model

Scope: a self-hosted Vaultwarden instance on a Debian VM under Proxmox, published to
the internet through a Cloudflare Tunnel, serving a small number of individual users
who connect with official Bitwarden clients.

This document states what the design protects against, what it does not, and where the
residual risk sits. Controls that are aspirational rather than implemented are marked
**[not implemented]** — a threat model that describes intentions as facts is worse than
no threat model.

---

## 1. Assets

| Asset | Where it lives | Consequence if lost |
| --- | --- | --- |
| Vault item ciphertext | `vw-data/db.sqlite3` | Confidentiality loss only if the master password is also known |
| Master passwords | Nowhere. Never transmitted, never stored | — |
| Per-user symmetric keys | Encrypted at rest, unwrapped client-side only | Full vault disclosure for that user |
| `rsa_key*` | `vw-data/` | Loss logs out every device; theft enables auth-token forgery |
| Attachments / Sends | `vw-data/attachments/`, `vw-data/sends/` | Direct file disclosure — these are **not** in the DB |
| `ADMIN_TOKEN` | `.env` (Argon2 hash) | Admin panel access: user management, settings |
| `TUNNEL_TOKEN` | `.env` | Lets an attacker stand up a tunnel into the network |
| Backup archives | `BACKUP_DIR` + off-box target | Equivalent to the database — encrypted at rest |

## 2. Trust boundaries

```
 [ client device ]     plaintext exists ONLY here, in memory, while unlocked
        │
        │  TLS to Cloudflare edge
        ▼
 [ Cloudflare ]        terminates TLS. Sees metadata. Sees ciphertext bodies.
        │              Does NOT see vault plaintext.
        │  tunnel (outbound-initiated, mutually authenticated)
        ▼
 [ cloudflared ]       only container that can reach vaultwarden
        │  internal docker network, no host route
        ▼
 [ vaultwarden ]       stores and serves ciphertext. Cannot decrypt any vault.
        │
        ▼
 [ vw-data volume ] ── [ Debian VM ] ── [ Proxmox host ]
```

The load-bearing property: **the server is not trusted with plaintext.** Vault items are
encrypted and decrypted on the client under a key derived from the master password via
Argon2id. Compromising the server, the hypervisor, Cloudflare, or the backups yields
ciphertext plus the ability to attack it offline — never plaintext directly.

## 3. Adversaries and what they get

### 3.1 Internet-wide opportunistic scanner
**Reaches:** nothing. There is no port-forward, no inbound firewall rule, and Vaultwarden
publishes no host port — `cloudflared` dials outbound. The VM's attack surface from the
public internet is the Cloudflare edge, not this network.
**Residual:** the hostname is discoverable (Certificate Transparency logs). Discovery is
not access.

### 3.2 Credential-stuffing / brute-force against a known account
**Reaches:** the login endpoint, through Cloudflare, like any legitimate client.
**Controls:** Argon2id KDF makes each guess expensive; TOTP 2FA on every account;
a Cloudflare WAF rate-limit rule on `/identity/connect/token`; Vaultwarden's own login
throttling.
**Residual — this is the single most realistic attack path.** A weak master password on
any account is not meaningfully mitigated by anything downstream. The strength of each
user's master password is a genuine control, not a formality.

### 3.3 Attacker who obtains a backup archive
**Reaches:** an `age`-encrypted tarball.
**Controls:** encryption to a key whose private half is deliberately stored off this
server; `chmod 600`; SHA-256 manifest.
**Residual:** if they get the age private key *and* the archive, they hold the database
— which is still per-user ciphertext requiring each master password to open.

### 3.4 Attacker with root on the Vaultwarden VM
**Reaches:** the database, `rsa_key`, attachments, `.env`, and — critically — the ability
to **modify the served web vault**. A tampered web-vault bundle can exfiltrate master
passwords from anyone who logs in through a browser.
**Controls:** browser extensions and desktop/mobile apps ship their own crypto code and
are **not** affected by a tampered server-side web vault. Setting `WEB_VAULT_ENABLED=false`
removes this path entirely at the cost of browser-based access.
**Residual:** real and significant for web-vault users. This is the strongest argument for
treating the extensions as the primary interface. VM compromise also means existing
ciphertext is exposed to offline attack.

### 3.5 One legitimate user attacking another's vault
**Reaches:** their own account, and rows belonging to others in the shared database.
**Controls:** this is the segregation requirement, and it holds **cryptographically, not
just by access control.** Each user's vault key is wrapped under a key derived from their
own master password. User B reading user A's `ciphers.data` directly out of SQLite gets
opaque base64. There is no server-side key that decrypts it, so there is no server-side
bug that can be coaxed into leaking it.
**Verification:** see README Step 4.4 — this is demonstrated empirically, not asserted.
**Residual:** users deliberately sharing via an Organization opt into shared access; that
is the feature working, not a failure.

### 3.6 Malicious or compromised Cloudflare
**Reaches:** all request metadata — which accounts sync, when, from which IPs, how often,
request sizes. Response bodies, but those are ciphertext.
**Additional exposure:** Cloudflare could serve modified web-vault JavaScript, the same
class of attack as 3.4, with the same mitigation (use the extensions).
**Residual:** accepted, and it is the price of remote access without opening a port. The
alternative — VPN-only (WireGuard/Tailscale) — removes Cloudflare from the trust boundary
entirely and is the right call if this exposure is unacceptable. **[not implemented]**

### 3.7 Compromised client device
**Reaches:** everything, once the vault is unlocked. Keyloggers, clipboard scrapers, and
malicious extensions all defeat every server-side control in this document.
**Controls:** short vault timeout, "lock on browser restart", and biometric unlock so the
master password is typed rarely.
**Residual:** unmitigable from the server side. Honestly the most likely real-world
compromise of any password manager, self-hosted or not.

### 3.8 Loss of the server (hardware failure, fire, ransomware)
**Reaches:** availability.
**Controls:** nightly encrypted backups shipped off-box; Proxmox VM backups underneath;
a rehearsed restore procedure with a dated log.
**Residual:** up to 24 hours of new items between backups. Acceptable for this use case;
the Bitwarden clients hold a local encrypted cache, so a server outage does not lock
anyone out of their existing passwords.

## 4. Design decisions and their rationale

| Decision | Why |
| --- | --- |
| Docker in a VM, not on the PVE host or in LXC | Keeps the hypervisor clean; snapshot-per-change; Docker-in-LXC needs nesting/keyctl and breaks unpredictably on upgrade |
| No published host port | Removes the entire class of LAN-side and port-scan attacks. Verified with `ss -tlnp` |
| Cloudflare Access on `/admin` **only** | Access in front of the whole hostname breaks every Bitwarden client — they cannot complete an interactive SSO challenge. `/api`, `/identity`, `/notifications` must stay reachable |
| `ADMIN_TOKEN` stored as an Argon2 hash | A plaintext token is readable via `docker inspect` and any file read on `.env` |
| `SIGNUPS_ALLOWED=false` + invitations | Registration is closed by default; open enrolment on an internet-reachable vault is how strangers end up in your database |
| `SHOW_PASSWORD_HINT=false` | An unauthenticated hint confirms an account exists and leaks a clue about the master password |
| Argon2id KDF (client-side) | Vaultwarden defaults to PBKDF2 for compatibility; Argon2id is memory-hard and much costlier to attack offline |
| Pinned image tag | An unattended pull that changes the schema is not a surprise you want on a vault |
| `sqlite3 .backup`, never `cp` | A file copy of a live SQLite DB restores cleanly and is silently corrupt |

## 5. Residual risk — the honest summary

Ranked by likelihood:

1. **A weak master password on any account.** Every other control is downstream of this.
2. **A compromised client device.** Nothing server-side helps.
3. **Web-vault tampering** via server or Cloudflare compromise. Mitigated by preferring
   the extensions; eliminated by `WEB_VAULT_ENABLED=false`.
4. **Cloudflare metadata visibility.** Accepted; VPN-only removes it.
5. **Operator error** — a `.env` committed to git, an unencrypted backup on a NAS share,
   a restore that was never rehearsed. `preflight.sh` checks the first two on every run;
   the restore drill addresses the third.

## 6. Not implemented

Named explicitly so the gaps are visible rather than implied:

- **VPN-only access** as an alternative to Cloudflare Tunnel (§3.6).
- **fail2ban** on the Vaultwarden log. Cloudflare WAF rate-limiting covers the same path
  at the edge; fail2ban would add defence in depth if the tunnel were ever bypassed.
- **Log shipping to a SIEM.** `EXTENDED_LOGGING` plus a real log file at
  `/data/vaultwarden.log` makes failed-login bursts greppable and ready to forward;
  nothing forwards them yet.
- **Automated restore verification.** The drill is currently manual and quarterly.
- **`WEB_VAULT_ENABLED=false`.** Left on for convenience, accepting §3.4.
