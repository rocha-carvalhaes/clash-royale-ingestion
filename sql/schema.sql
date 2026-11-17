CREATE TABLE IF NOT EXISTS players_watchlist (
    player_tag      TEXT PRIMARY KEY,           -- '#ABC123'
    is_active       BOOLEAN NOT NULL DEFAULT true,
    added_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_fetched_at TIMESTAMPTZ,
    last_battle_at  TIMESTAMPTZ                 -- battleTime mais recente visto
);

CREATE TABLE IF NOT EXISTS fetch_log (
    fetch_id      UUID PRIMARY KEY,
    endpoint      TEXT NOT NULL,                -- 'battlelog', 'player', 'cards', ...
    subject_tag   TEXT,                         -- nulo para endpoints globais
    run_id        TEXT NOT NULL,                -- identificador da execução diária
    requested_at  TIMESTAMPTZ NOT NULL,
    status_code   INT,
    error_class   TEXT,                         -- 'timeout', 'rate_limited', 'forbidden', 'not_found', 'server_error'
    latency_ms    INT,
    bytes         INT,
    gcs_uri       TEXT
);

CREATE INDEX IF NOT EXISTS fetch_log_run_idx ON fetch_log (run_id);
CREATE INDEX IF NOT EXISTS fetch_log_subject_idx ON fetch_log (subject_tag, requested_at DESC);
