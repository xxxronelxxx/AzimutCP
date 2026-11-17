//! Server software catalog: PHP, databases, caches, Node.js and common tools.
//!
//! Install/remove operations are executed by `/usr/local/sbin/azimut-software`
//! through a narrow sudo rule. The helper validates every id/version against a
//! hardcoded allowlist; the API only accepts values from this catalog.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc};

use super::auth::Claims;
use crate::{ApiError, ApiResult, AppState};

// ── Catalog ───────────────────────────────────────────────────────────────────

struct ItemDef {
    id: &'static str,
    name: &'static str,
    category: &'static str,
    description: &'static str,
    versions: &'static [&'static str],
    removable: bool,
}

const PHP_VERSIONS: &[&str] = &[
    "8.5", "8.4", "8.3", "8.2", "8.1", "8.0", "7.4", "7.3", "7.2", "7.1", "7.0", "5.6",
];
const PG_VERSIONS: &[&str] = &["17", "16", "15", "14", "13", "12", "11", "10"];
const NODE_VERSIONS: &[&str] = &["24", "22", "20", "18", "16"];
const SINGLE: &[&str] = &["latest"];

const CATALOG: &[ItemDef] = &[
    ItemDef {
        id: "php",
        name: "PHP",
        category: "PHP",
        description: "PHP-FPM with the usual extension set.",
        versions: PHP_VERSIONS,
        removable: true,
    },
    ItemDef {
        id: "postgresql",
        name: "PostgreSQL",
        category: "Databases",
        description: "PostgreSQL server from the official PGDG repository.",
        versions: PG_VERSIONS,
        removable: true,
    },
    ItemDef {
        id: "mysql",
        name: "MySQL",
        category: "Databases",
        description: "MySQL 8.4 LTS from the official Oracle APT repository.",
        versions: &["8.4"],
        removable: true,
    },
    ItemDef {
        id: "mariadb",
        name: "MariaDB",
        category: "Databases",
        description: "MariaDB 11.x from the official MariaDB repository.",
        versions: &["11.8", "11.4"],
        removable: true,
    },
    ItemDef {
        id: "redis",
        name: "Redis",
        category: "Cache",
        description: "In-memory key/value store. The panel uses Redis/Valkey for its job queue.",
        versions: SINGLE,
        removable: false,
    },
    ItemDef {
        id: "valkey",
        name: "Valkey",
        category: "Cache",
        description: "Redis-compatible store used by the panel by default.",
        versions: SINGLE,
        removable: false,
    },
    ItemDef {
        id: "memcached",
        name: "Memcached",
        category: "Cache",
        description: "Distributed memory object cache.",
        versions: SINGLE,
        removable: true,
    },
    ItemDef {
        id: "nodejs",
        name: "Node.js",
        category: "Runtimes",
        description: "Node.js runtime installed system-wide via nvm; the panel's own Node.js is untouched.",
        versions: NODE_VERSIONS,
        removable: true,
    },
    ItemDef {
        id: "composer",
        name: "Composer",
        category: "Tools",
        description: "PHP dependency manager.",
        versions: SINGLE,
        removable: true,
    },
    ItemDef {
        id: "git",
        name: "Git",
        category: "Tools",
        description: "Version control (used by push-to-deploy).",
        versions: SINGLE,
        removable: true,
    },
    ItemDef {
        id: "fail2ban",
        name: "fail2ban",
        category: "Security",
        description: "Intrusion prevention for SSH, mail and the panel.",
        versions: SINGLE,
        removable: true,
    },
    ItemDef {
        id: "jpegoptim",
        name: "jpegoptim",
        category: "Tools",
        description: "JPEG optimisation utility.",
        versions: SINGLE,
        removable: true,
    },
    ItemDef {
        id: "phpmyadmin",
        name: "phpMyAdmin",
        category: "Web tools",
        description: "MySQL/MariaDB web interface (package only; vhost is not created automatically).",
        versions: SINGLE,
        removable: true,
    },
    ItemDef {
        id: "phppgadmin",
        name: "phpPgAdmin",
        category: "Web tools",
        description: "PostgreSQL web interface (package only).",
        versions: SINGLE,
        removable: true,
    },
    ItemDef {
        id: "roundcube",
        name: "Roundcube",
        category: "Mail",
        description: "Webmail (package only; SSO helpers live in scripts/roundcube).",
        versions: SINGLE,
        removable: true,
    },
    ItemDef {
        id: "spamassassin",
        name: "SpamAssassin",
        category: "Mail",
        description: "Spam filter daemon.",
        versions: SINGLE,
        removable: true,
    },
    ItemDef {
        id: "sftp",
        name: "SFTP",
        category: "Tools",
        description: "OpenSSH SFTP subsystem.",
        versions: SINGLE,
        removable: true,
    },
];

const HELPER: &str = "/usr/local/sbin/azimut-software";

// ── API types ─────────────────────────────────────────────────────────────────

#[derive(Serialize)]
struct VersionStatus {
    version: String,
    installed: bool,
    in_use: i64,
    error: Option<String>,
}

#[derive(Serialize)]
struct SoftwareItem {
    id: String,
    name: String,
    category: String,
    description: String,
    removable: bool,
    url: Option<String>,
    versions: Vec<VersionStatus>,
}

#[derive(Deserialize, Default)]
struct VersionRequest {
    #[serde(default)]
    version: String,
}

// ── Router ────────────────────────────────────────────────────────────────────

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/v1/software", get(list_software))
        .route("/api/v1/software/{id}/install", post(install_software))
        .route("/api/v1/software/{id}/uninstall", post(uninstall_software))
}

// ── Detection ─────────────────────────────────────────────────────────────────

fn bin_exists(bin: &str) -> bool {
    std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("command -v {bin}"))
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn pkg_installed(pkg: &str) -> bool {
    std::process::Command::new("dpkg-query")
        .args(["-W", "-f=${Status}", pkg])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("install ok installed"))
        .unwrap_or(false)
}

fn command_version(cmd: &str, arg: &str) -> String {
    std::process::Command::new(cmd)
        .arg(arg)
        .output()
        .ok()
        .map(|o| {
            let mut s = String::from_utf8_lossy(&o.stdout).to_string();
            s.push_str(&String::from_utf8_lossy(&o.stderr));
            s
        })
        .unwrap_or_default()
}

struct Ctx {
    php: Vec<String>,
    php_sites: HashMap<String, i64>,
    db_sites: HashMap<String, i64>,
    node_versions: Vec<String>,
    mysql_version: String,
    mariadb_version: String,
}

impl Ctx {
    async fn load(state: &AppState) -> ApiResult<Self> {
        let php = crate::api::php::detect_installed_php_versions();

        let php_rows = sqlx::query!(
            r#"SELECT php_version, COUNT(*) AS "count!"
               FROM sites WHERE deleted_at IS NULL GROUP BY php_version"#
        )
        .fetch_all(&state.db)
        .await?;
        let php_sites = php_rows
            .into_iter()
            .map(|r| (r.php_version, r.count))
            .collect();

        let db_rows = sqlx::query!(
            r#"SELECT db_type::text AS "db_type!", COUNT(*) AS "count!"
               FROM databases GROUP BY db_type"#
        )
        .fetch_all(&state.db)
        .await?;
        let db_sites = db_rows
            .into_iter()
            .map(|r| (r.db_type, r.count))
            .collect();

        let mut node_versions = Vec::new();
        if let Ok(entries) = std::fs::read_dir("/opt/azimutcp/nvm/versions/node") {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if let Some(ver) = name.strip_prefix('v') {
                    if let Some(major) = ver.split('.').next() {
                        node_versions.push(major.to_string());
                    }
                }
            }
        }

        let mysqld_raw = command_version("mysqld", "--version");
        let mysqld = mysqld_raw.to_lowercase();
        let version_re = regex::Regex::new(r"(\d+\.\d+(?:\.\d+)?)").unwrap();
        let detected = version_re
            .captures(&mysqld_raw)
            .map(|c| c[1].to_string())
            .unwrap_or_default();
        let mariadb_version = if mysqld.contains("mariadb") { detected.clone() } else { String::new() };
        let mysql_version = if !mysqld.is_empty() && !mysqld.contains("mariadb") { detected } else { String::new() };

        Ok(Self { php, php_sites, db_sites, node_versions, mysql_version, mariadb_version })
    }

    fn installed(&self, id: &str, version: &str) -> bool {
        match id {
            "php" => self.php.iter().any(|v| v == version),
            "postgresql" => {
                std::path::Path::new(&format!("/etc/postgresql/{version}")).exists()
                    || std::path::Path::new(&format!("/usr/lib/postgresql/{version}/bin/postgres")).exists()
            }
            "mysql" => self.mysql_version.starts_with(version),
            "mariadb" => self.mariadb_version.starts_with(version),
            "redis" => bin_exists("redis-server"),
            "valkey" => bin_exists("valkey-server") || bin_exists("redis-server"),
            "memcached" => bin_exists("memcached"),
            "nodejs" => self.node_versions.iter().any(|v| v == version),
            "composer" => bin_exists("composer"),
            "git" => bin_exists("git"),
            "fail2ban" => bin_exists("fail2ban-client"),
            "jpegoptim" => bin_exists("jpegoptim"),
            "phpmyadmin" => pkg_installed("phpmyadmin") || std::path::Path::new("/etc/phpmyadmin").exists(),
            "phppgadmin" => pkg_installed("phppgadmin"),
            "roundcube" => pkg_installed("roundcube") || std::path::Path::new("/usr/share/roundcube").exists(),
            "spamassassin" => pkg_installed("spamassassin"),
            "sftp" => pkg_installed("openssh-sftp-server"),
            _ => false,
        }
    }

    fn in_use(&self, id: &str, version: &str) -> i64 {
        match id {
            "php" => self.php_sites.get(version).copied().unwrap_or(0),
            "mysql" => self.db_sites.get("mysql").copied().unwrap_or(0)
                + self.db_sites.get("mariadb").copied().unwrap_or(0),
            "mariadb" => self.db_sites.get("mariadb").copied().unwrap_or(0),
            "postgresql" => self.db_sites.get("postgres").copied().unwrap_or(0),
            _ => 0,
        }
    }
}

// ── Handlers ──────────────────────────────────────────────────────────────────

async fn list_software(
    State(state): State<Arc<AppState>>,
    claims: Claims,
) -> ApiResult<Json<Vec<SoftwareItem>>> {
    require_admin(&claims)?;
    let ctx = Ctx::load(&state).await?;
    let mut conn = state.valkey.clone();

    let mut out = Vec::new();
    for def in CATALOG {
        let mut versions = Vec::new();
        for v in def.versions {
            let error: Option<String> = redis::cmd("GET")
                .arg(format!("azimut:software:error:{}:{}", def.id, v))
                .query_async(&mut conn)
                .await
                .unwrap_or(None);
            versions.push(VersionStatus {
                version: (*v).to_string(),
                installed: ctx.installed(def.id, v),
                in_use: ctx.in_use(def.id, v),
                error,
            });
        }
        let web_url = match def.id {
            "phpmyadmin" | "phppgadmin" | "roundcube"
                if versions.iter().any(|v| v.installed) =>
            {
                let domain = &state.config.panel_domain;
                if domain.parse::<std::net::IpAddr>().is_ok() {
                    let port = match def.id {
                        "phpmyadmin" => 8081,
                        "phppgadmin" => 8082,
                        "roundcube" => 8083,
                        _ => 80,
                    };
                    Some(format!("http://{domain}:{port}/"))
                } else {
                    Some(format!("http://{}.{domain}/", def.id))
                }
            }
            _ => None,
        };

        out.push(SoftwareItem {
            id: def.id.to_string(),
            name: def.name.to_string(),
            category: def.category.to_string(),
            description: def.description.to_string(),
            removable: def.removable,
            url: web_url,
            versions,
        });
    }

    Ok(Json(out))
}

async fn install_software(
    State(state): State<Arc<AppState>>,
    claims: Claims,
    Path(id): Path<String>,
    Json(req): Json<VersionRequest>,
) -> ApiResult<(StatusCode, Json<serde_json::Value>)> {
    queue_action(state, claims, id, req.version, "install").await
}

async fn uninstall_software(
    State(state): State<Arc<AppState>>,
    claims: Claims,
    Path(id): Path<String>,
    Json(req): Json<VersionRequest>,
) -> ApiResult<(StatusCode, Json<serde_json::Value>)> {
    queue_action(state, claims, id, req.version, "remove").await
}

async fn queue_action(
    state: Arc<AppState>,
    claims: Claims,
    id: String,
    version: String,
    action: &'static str,
) -> ApiResult<(StatusCode, Json<serde_json::Value>)> {
    require_admin(&claims)?;

    let def = CATALOG.iter().find(|d| d.id == id).ok_or_else(|| {
        ApiError::Validation(format!("Unknown software id: {id}"))
    })?;

    if !def.versions.iter().any(|v| *v == version) {
        return Err(ApiError::Validation(format!(
            "Unsupported version '{version}' for {id}"
        )));
    }

    if action == "remove" {
        if !def.removable {
            return Err(ApiError::Forbidden(format!(
                "{id} is used by the panel and cannot be removed"
            )));
        }
        if id == "php" {
            let in_use: i64 = sqlx::query_scalar!(
                r#"SELECT COUNT(*) AS "count!" FROM sites
                   WHERE php_version = $1 AND deleted_at IS NULL"#,
                version
            )
            .fetch_one(&state.db)
            .await?;
            if in_use > 0 {
                return Err(ApiError::Validation(format!(
                    "PHP {version} is used by {in_use} site(s); move them to another version first"
                )));
            }
        }
        if id == "postgresql" {
            let dbs: i64 = sqlx::query_scalar!(
                r#"SELECT COUNT(*) AS "count!" FROM databases WHERE db_type::text = 'postgres'"#
            )
            .fetch_one(&state.db)
            .await?;
            if dbs > 0 {
                return Err(ApiError::Validation(
                    "PostgreSQL still hosts databases; drop or move them before removing the server".into(),
                ));
            }
        }
        if id == "mysql" || id == "mariadb" {
            let dbs: i64 = sqlx::query_scalar!(
                r#"SELECT COUNT(*) AS "count!" FROM databases
                   WHERE db_type::text IN ('mysql', 'mariadb')"#
            )
            .fetch_one(&state.db)
            .await?;
            if dbs > 0 {
                return Err(ApiError::Validation(
                    "The database server still hosts databases; drop them before removing it".into(),
                ));
            }
        }
        if id == "nodejs" {
            let prefix = format!("{version}%");
            let sites: i64 = sqlx::query_scalar!(
                r#"SELECT COUNT(*) AS "count!" FROM sites
                   WHERE runtime = 'nodejs' AND runtime_version LIKE $1
                     AND deleted_at IS NULL"#,
                prefix
            )
            .fetch_one(&state.db)
            .await?;
            if sites > 0 {
                return Err(ApiError::Validation(format!(
                    "Node.js {version} is used by {sites} site(s); switch them first"
                )));
            }
        }
    }

    if !std::path::Path::new(HELPER).exists() {
        return Err(ApiError::Validation(
            "Software installer helper is missing. Re-run the installer.".into(),
        ));
    }

    // One operation per package/version at a time.
    {
        use redis::AsyncCommands;
        let mut conn = state.valkey.clone();
        let lock = format!("azimut:software:lock:{}:{}", id, version);
        let acquired: Option<String> = redis::cmd("SET")
            .arg(&lock)
            .arg("1")
            .arg("NX")
            .arg("EX")
            .arg(1800)
            .query_async(&mut conn)
            .await
            .unwrap_or(None);
        if acquired.is_none() {
            return Err(ApiError::Validation(format!(
                "An operation for {id} {version} is already running"
            )));
        }

        let job = serde_json::json!({
            "type": if action == "install" { "install_software" } else { "uninstall_software" },
            "id": id,
            "version": version,
        });
        let _: () = conn.lpush("azimut:jobs", job.to_string()).await.unwrap_or(());
    }

    tracing::info!(software = %id, version = %version, action, "software operation queued");
    Ok((
        StatusCode::ACCEPTED,
        Json(serde_json::json!({ "status": "queued", "id": id, "version": version, "action": action })),
    ))
}

// ── Access helper ─────────────────────────────────────────────────────────────

fn require_admin(claims: &Claims) -> ApiResult<()> {
    if claims.role != "admin" {
        return Err(ApiError::Forbidden("Administrators only".into()));
    }
    Ok(())
}
