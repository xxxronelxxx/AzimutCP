# AzimutCP WHMCS Provisioning Module

Automates account create/suspend/unsuspend/terminate/change-package/usage/SSO for AzimutCP from WHMCS.

## Requirements

- WHMCS 8.x
- PHP 8.1+ with `ext-curl` and `ext-json`
- AzimutCP panel v1.0+ (API v1.1)

## Installation

1. Copy the `azimutcp/` directory to your WHMCS server:

   ```
   /path/to/whmcs/modules/servers/azimutcp/
   ```

2. In WHMCS **Setup → Products/Services → Servers**, add a new server:
   - **Type**: AzimutCP Web Hosting
   - **Hostname**: your AzimutCP panel hostname or IP (e.g. `cp.example.com`)
   - **Password**: an AzimutCP admin API token (generated in *Settings → API Keys*)
   - Leave **Username** blank — the module stores the AzimutCP user ID per service.

3. Create or edit a WHMCS Product and assign it to your AzimutCP server group.
   In the **Module Settings** tab configure:

   | Option | Description | Default |
   |---|---|---|
   | AzimutCP Package Name | Plan name in AzimutCP (e.g. `basic`, `pro`) | `basic` |
   | Disk Quota (GB) | Hard disk limit for the account | `10` |
   | Max Email Accounts | Max email addresses | `50` |
   | Max Databases | Max databases | `10` |
   | Web Server | `openlitespeed`, `nginx`, or `apache` | `openlitespeed` |
   | Default PHP Version | `8.4`, `8.3`, `8.2`, or `8.1` | `8.3` |

## Module Hooks

| Hook | AzimutCP API call | Notes |
|---|---|---|
| `CreateAccount` | `POST /api/v1/users` + `POST /api/v1/sites` | Creates user + primary site; rolls back user on site failure |
| `SuspendAccount` | `POST /api/v1/users/{id}/suspend` | Disables login + web access |
| `UnsuspendAccount` | `POST /api/v1/users/{id}/unsuspend` | Restores access |
| `TerminateAccount` | `DELETE /api/v1/sites/{id}` × N + `DELETE /api/v1/users/{id}` | Deletes all sites then user |
| `ChangePackage` | `PUT /api/v1/users/{id}` | Updates plan + disk quota |
| `UsageUpdate` | `GET /api/v1/users/{id}/stats` | Nightly disk usage sync |
| `LoginLink` | `POST /api/v1/users/{id}/impersonate` | 5-min SSO token, renders button |

## API Token

Generate an API token in AzimutCP: **Admin → Settings → API Keys → Create Token**.
Use a dedicated token with `Admin` role. Store it in the WHMCS server record's **Password** field.
Tokens are scoped; use `Bearer` authentication.

## Troubleshooting

- **"No AzimutCP user ID on record"** — the service was likely created outside of WHMCS or the
  `CreateAccount` hook failed to save the user ID. Manually enter the AzimutCP user UUID into the
  WHMCS service `username` field.
- **SSL errors** — ensure the AzimutCP panel has a valid TLS certificate. If using a self-signed
  cert in development, set `CURLOPT_SSL_VERIFYPEER => false` in `_azimutcp_api()` (not for
  production).
- **Timeout** — increase `CURLOPT_TIMEOUT` in `_azimutcp_api()` if the AzimutCP server is slow.

## Blesta Module

A Blesta provisioning module using the same AzimutCP API v1 endpoints is planned for a future
release. The API surface is identical; only the Blesta module scaffold differs.
