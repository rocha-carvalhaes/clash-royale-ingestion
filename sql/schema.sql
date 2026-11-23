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
    error_class   TEXT,                         -- 'timeout', 'network_error', 'rate_limited', 'forbidden', 'not_found', 'server_error', 'storage_error'
    latency_ms    INT,
    bytes         INT,
    gcs_uri       TEXT
);

CREATE INDEX IF NOT EXISTS fetch_log_run_idx ON fetch_log (run_id);
CREATE INDEX IF NOT EXISTS fetch_log_subject_idx ON fetch_log (subject_tag, requested_at DESC);

-- Uma linha por execução. 'running' sem finished_at por muito tempo = execução travada/morta.
CREATE TABLE IF NOT EXISTS run_log (
    run_id        TEXT PRIMARY KEY,
    started_at    TIMESTAMPTZ NOT NULL,
    finished_at   TIMESTAMPTZ,
    status        TEXT NOT NULL,                -- 'running', 'success', 'partial', 'fatal', 'crashed'
    host          TEXT,
    tags_total    INT,
    tags_ok       INT,
    tags_failed   INT,
    bytes_total   BIGINT,
    error_message TEXT
);

CREATE INDEX IF NOT EXISTS run_log_started_idx ON run_log (started_at DESC);

-- Volumetria (adicionadas depois; ADD COLUMN IF NOT EXISTS mantém o script reexecutável)
ALTER TABLE fetch_log ADD COLUMN IF NOT EXISTS battles_count     INT;  -- batalhas no corpo
ALTER TABLE fetch_log ADD COLUMN IF NOT EXISTS new_battles_count INT;  -- mais recentes que o last_battle_at anterior
ALTER TABLE run_log   ADD COLUMN IF NOT EXISTS battles_total     INT;
ALTER TABLE run_log   ADD COLUMN IF NOT EXISTS new_battles_total INT;
