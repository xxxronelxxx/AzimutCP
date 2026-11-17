# Testing AzimutCP on a VM

This describes the **minimal test build**: panel API + UI + PostgreSQL +
Valkey + nginx. Mail, DNS (PowerDNS), Apache/OLS, quotas and cgroups are not
configured — those need the full installer and a real hosting setup.

Use a **fresh** Ubuntu 22.04/24.04 or Debian 12 VM. Do not run this on a
production server.

## 1. Get the build

Download the latest release bundle from GitHub:

<https://github.com/xxxronelxxx/AzimutCP/releases>

File: `azimutcp-linux-x86_64.tar.gz` (x86_64). ARM64 is not built yet.

```bash
curl -LO https://github.com/xxxronelxxx/AzimutCP/releases/latest/download/azimutcp-linux-x86_64.tar.gz
tar -xzf azimutcp-linux-x86_64.tar.gz
```

The archive contains:

```
bin/                  azimut-panel, azimut-agent, azimut-dns, azimut-mail,
                      azimut-cron, azimut-cli, azimut-mcp
ui/ui.tar.gz          prebuilt SvelteKit UI
apps/                 app catalog manifests
scripts/              Roundcube / SOGo SSO helpers
install-test.sh       test installer
```

## 2. Install

```bash
sudo ./install-test.sh
```

Or pass the panel address explicitly (domain or IP):

```bash
sudo ./install-test.sh cp.example.com
```

The script installs packages, creates the `azimutcp` user and database, writes
`/etc/azimutcp/panel.env`, starts `azimut-panel` and `azimut-ui`, and configures
nginx on port 80.

At the end it prints:

```
Open:     http://<address>/
Email:    admin@<address>
Password: <generated>
```

The admin account is created automatically by the panel on first start.

## 3. What to check

- sign in, dashboard loads;
- create a site (provisioning will fail in the minimal build unless the host
  is fully configured — expected);
- users, settings, audit log, firewall pages load;
- browser console has no errors; UI WebSocket connects (`/ws/`).

## 4. Logs and configuration

```bash
journalctl -u azimut-panel -f
journalctl -u azimut-ui -f
cat /etc/azimutcp/panel.env
```

Health endpoints:

```bash
curl -s http://127.0.0.1:2087/health
curl -s http://127.0.0.1:2087/health/ready
```

## 5. Re-running

Re-running the installer keeps the database password and admin credentials
already present in `/etc/azimutcp/panel.env`, and replaces binaries, UI and
unit files. Migrations are applied by the panel on startup.

## 6. Rebuild from source

If you need to build the bundle yourself, see the release workflow:
`.github/workflows/release.yml`. Locally on Linux:

```bash
# PostgreSQL is required at compile time (sqlx::query! macros)
export DATABASE_URL=postgres://user:pass@127.0.0.1:5432/azimutcp
sqlx migrate run --source azimut-panel/migrations

cargo build --release --workspace
( cd azimut-ui && npm ci && npm run build )
```

`protobuf-compiler` is required for the gRPC bindings.
