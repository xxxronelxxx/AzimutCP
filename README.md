<div align="center">

# AzimutCP

**Rust-powered web hosting control panel**

[![License](https://img.shields.io/badge/License-AGPL--3.0-blue?style=for-the-badge)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux-orange?style=for-the-badge&logo=linux)](https://github.com/xxxronelxxx/AzimutCP)
[![Rust](https://img.shields.io/badge/Built%20With-Rust-b7410e?style=for-the-badge&logo=rust)](https://www.rust-lang.org)

[**Issues**](https://github.com/xxxronelxxx/AzimutCP/issues) · [**Source**](https://github.com/xxxronelxxx/AzimutCP) · [**License**](LICENSE)

</div>

---

> **Status: alpha.** AzimutCP is an active fork of
> [OrbitCP](https://github.com/multidigitaltools/OrbitCP) (AGPL-3.0), being
> reworked into an independent panel. Interfaces, installers and database
> migrations may change without notice. See [NOTICE](NOTICE) for attribution.

## What it is

AzimutCP manages Linux web-hosting servers: websites, mail, DNS, databases,
SSL, firewalls, backups, cron and PHP versions. The control plane is written in
Rust (axum + tokio + sqlx), the UI is SvelteKit, and every managed server runs
the `azimut-agent` daemon over mutual TLS.

## Features

| Area | Capabilities |
|---|---|
| Websites | one-form creation, aliases, per-site PHP 8.1–8.4, PHP settings and extensions, document root, disk quotas |
| Web servers | nginx, Apache, OpenLiteSpeed (per-site selection) |
| Databases | MySQL/MariaDB, PostgreSQL, per-site users, DB manager |
| Mail | Postfix + Dovecot + rspamd, domains, mailboxes, forwarders, autoresponders, DKIM/SPF/DMARC, Sieve, queue |
| DNS | PowerDNS integration through `azimut-dns`, zones, records, DNSSEC, propagation checks, Cloudflare |
| SSL | Let's Encrypt (HTTP-01 / DNS-01), auto-renewal, custom certificates |
| Security | mandatory TOTP, ES256 JWT + JTI blocklist, per-IP rate limits, admin IP allowlist, audit log, fail2ban, nftables, ModSecurity |
| Operations | backups (files + databases), cron, file manager, logs, metrics, WebSocket dashboard, notifications |
| Extras | 1-click app catalog, WordPress/WP-CLI, git push-to-deploy, staging, resellers, client portal, WHMCS module, REST API, CLI, MCP server |

## Architecture

```
HTTPS :443 → nginx → azimut-panel (127.0.0.1:2087)
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
    PostgreSQL       Valkey/Redis      azimut-dns ──► PowerDNS
    (all state)      (cache + jobs)         │
                          │                 │
                    azimut-mail ──► Postfix/Dovecot/rspamd
                          │
                gRPC mTLS :7443
                azimut-agent (per server, SQLite journal)
```

Daemons: `azimut-panel` · `azimut-agent` · `azimut-dns` · `azimut-mail` · `azimut-cron` · `azimut-cli` · `azimut-mcp`.

## Requirements

- Ubuntu 22.04 / 24.04 LTS, Debian 11 / 12
- 1 GB RAM minimum, 20 GB disk
- PostgreSQL 15+, Valkey or Redis 7+
- Rust 1.80+ (when building from source), Node.js 20+ for the UI

## Install (one command)

Fresh Ubuntu 22.04 / 24.04 or Debian 12, x86_64, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/xxxronelxxx/AzimutCP/main/install.sh | sudo bash
```

With a panel address (domain or IP):

```bash
curl -fsSL https://raw.githubusercontent.com/xxxronelxxx/AzimutCP/main/install.sh | sudo bash -s -- cp.example.com
```

The installer downloads the latest release bundle, verifies its SHA-256
checksum and sets up the panel API, the UI, PostgreSQL, Valkey, nginx and
systemd units. Credentials for the initial admin account are printed at the
end.

This is the **minimal install**: nginx, PHP 8.4, MariaDB 11, PostgreSQL and
the mail stack are ready to use. PowerDNS, Apache/OLS, quotas and cgroups are
not configured yet. See [TESTING.md](TESTING.md) for details and
troubleshooting.

A source build (no prebuilt bundle) is available as
`installer/install-from-source.sh`.

## Build from source

```bash
git clone https://github.com/xxxronelxxx/AzimutCP.git
cd AzimutCP

# Panel configuration
cp azimut-panel/.env.example .env      # edit DATABASE_URL and friends

# Daemons
cargo build --release --workspace

# UI
cd azimut-ui && npm install && npm run build

# Migrations run automatically when azimut-panel starts
./target/release/azimut-panel
```

The panel listens on `127.0.0.1:2087` and must be reverse-proxied by nginx.
`DATABASE_URL` is the only mandatory environment variable.

## Repository layout

```
azimut-panel/    panel API, business logic, background jobs
azimut-agent/    gRPC/mTLS agent for managed servers
azimut-dns/      PowerDNS REST proxy
azimut-mail/     Postfix/Dovecot/rspamd file management
azimut-cron/     scheduler (SSL, backups, DNSBL, metrics)
azimut-cli/      `azimut` command-line client
azimut-mcp/      MCP server (stdio / HTTP)
azimut-ui/       SvelteKit frontend
installer/       extended installer, systemd units, hardening
proto/           gRPC service definitions
scripts/         Roundcube/SOGo SSO helpers
```

## Roadmap

1. Stabilisation: at-least-once job queue, agent RPC coverage, metrics, tests and CI.
2. FastPanel-style website creation: aliases, database, mail, DNS and SSL in one flow.
3. Production packaging: unattended installs, self-update, signed releases.
4. Separate fleet service for managing multiple panels (optional, later).
5. Docker app hosting and web terminal.

## License and attribution

AzimutCP is distributed under the **GNU Affero General Public License v3.0 or
later**. It is based on OrbitCP, Copyright (C) 2026 MultiDigitalTools, also
licensed under AGPL-3.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Because the panel is used over a network, AGPL-3.0 requires that users can
obtain the corresponding source code. The source is this repository; keep the
link available in your deployment.

## Contributing

Issues and pull requests are welcome at
[github.com/xxxronelxxx/AzimutCP](https://github.com/xxxronelxxx/AzimutCP).
