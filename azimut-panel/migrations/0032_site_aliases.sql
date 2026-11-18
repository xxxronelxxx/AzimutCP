-- Additional domains served by a site.
CREATE TABLE IF NOT EXISTS site_aliases (
    site_id    UUID         NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    domain     VARCHAR(253) NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (site_id, domain)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_site_aliases_domain ON site_aliases(domain);
