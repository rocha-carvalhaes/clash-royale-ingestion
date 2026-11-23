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

-- Uma linha: a situação atual, para o topo do painel.
CREATE OR REPLACE VIEW vw_ingestion_status AS
SELECT
    r.run_id                       AS last_run_id,
    r.started_at                   AS last_run_started_at,
    r.status                       AS last_run_status,
    r.error_message                AS last_run_error,
    s.last_success_at,
    round(extract(epoch FROM now() - s.last_success_at) / 3600, 1) AS hours_since_last_success,
    CASE
        WHEN s.last_success_at IS NULL OR now() - s.last_success_at > interval '26 hours' THEN 'atrasado'
        WHEN r.status IN ('fatal', 'crashed') THEN 'erro'
        WHEN r.status = 'partial' THEN 'parcial'
        ELSE 'ok'
    END                            AS health
FROM (SELECT * FROM run_log ORDER BY started_at DESC LIMIT 1) r
CROSS JOIN (SELECT max(finished_at) AS last_success_at FROM run_log
            WHERE status IN ('success', 'partial')) s;

-- Histórico de execuções.
CREATE OR REPLACE VIEW vw_run_summary AS
SELECT
    run_id,
    started_at,
    finished_at,
    round(extract(epoch FROM finished_at - started_at)::numeric, 1) AS duration_s,
    status,
    tags_total,
    tags_ok,
    tags_failed,
    bytes_total,
    error_message,
    host
FROM run_log;

-- Situação de cada jogador da watchlist.
CREATE OR REPLACE VIEW vw_player_health AS
SELECT
    w.player_tag,
    w.is_active,
    w.last_fetched_at,
    w.last_battle_at,
    round(extract(epoch FROM now() - w.last_battle_at) / 86400, 1) AS days_since_last_battle,
    last_fetch.status_code         AS last_status_code,
    last_fetch.error_class         AS last_error_class,
    coalesce(recent.failures_7d, 0) AS failures_7d,
    coalesce(recent.fetches_7d, 0)  AS fetches_7d
FROM players_watchlist w
LEFT JOIN LATERAL (
    SELECT status_code, error_class FROM fetch_log f
    WHERE f.subject_tag = w.player_tag AND f.endpoint = 'battlelog'
    ORDER BY requested_at DESC LIMIT 1
) last_fetch ON true
LEFT JOIN LATERAL (
    SELECT count(*) AS fetches_7d, count(*) FILTER (WHERE error_class IS NOT NULL) AS failures_7d
    FROM fetch_log f
    WHERE f.subject_tag = w.player_tag AND f.requested_at > now() - interval '7 days'
) recent ON true;

-- Agregado diário das chamadas, para gráficos de tendência.
CREATE OR REPLACE VIEW vw_fetch_daily AS
SELECT
    (requested_at AT TIME ZONE 'UTC')::date               AS day,
    endpoint,
    count(*)                                               AS fetches,
    count(*) FILTER (WHERE error_class IS NULL)            AS ok,
    count(*) FILTER (WHERE error_class IS NOT NULL)        AS failed,
    round(avg(latency_ms))                                 AS avg_latency_ms,
    sum(bytes)                                             AS bytes
FROM fetch_log
GROUP BY 1, 2;
