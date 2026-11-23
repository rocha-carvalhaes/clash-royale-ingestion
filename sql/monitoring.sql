-- Views de saúde e volumetria da ingestão (consumidas pelo painel do Looker Studio).
-- Aplicar depois de schema.sql. Reexecutável: as views são recriadas.

CREATE SCHEMA IF NOT EXISTS monitoring;

-- Nomes antigos (prefixo vw_ em public), removidos na migração para o schema monitoring.
DROP VIEW IF EXISTS public.vw_ingestion_status, public.vw_run_summary, public.vw_player_health,
                    public.vw_fetch_daily, public.vw_battle_gaps;

DROP VIEW IF EXISTS monitoring.ingestion_status, monitoring.run_summary, monitoring.player_health,
                    monitoring.fetch_daily, monitoring.battle_gaps;

-- Uma linha: a situação atual, para o topo do painel.
CREATE VIEW monitoring.ingestion_status AS
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
FROM (SELECT * FROM public.run_log ORDER BY started_at DESC LIMIT 1) r
CROSS JOIN (SELECT max(finished_at) AS last_success_at FROM public.run_log
            WHERE status IN ('success', 'partial')) s;

-- Histórico de execuções.
CREATE VIEW monitoring.run_summary AS
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
    battles_total,
    new_battles_total,
    error_message,
    host
FROM public.run_log;

-- Situação de cada jogador da watchlist.
CREATE VIEW monitoring.player_health AS
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
FROM public.players_watchlist w
LEFT JOIN LATERAL (
    SELECT status_code, error_class FROM public.fetch_log f
    WHERE f.subject_tag = w.player_tag AND f.endpoint = 'battlelog'
    ORDER BY requested_at DESC LIMIT 1
) last_fetch ON true
LEFT JOIN LATERAL (
    SELECT count(*) AS fetches_7d, count(*) FILTER (WHERE error_class IS NOT NULL) AS failures_7d
    FROM public.fetch_log f
    WHERE f.subject_tag = w.player_tag AND f.requested_at > now() - interval '7 days'
) recent ON true;

-- Agregado diário das chamadas, para gráficos de tendência.
CREATE VIEW monitoring.fetch_daily AS
SELECT
    (requested_at AT TIME ZONE 'UTC')::date               AS day,
    endpoint,
    count(*)                                               AS fetches,
    count(*) FILTER (WHERE error_class IS NULL)            AS ok,
    count(*) FILTER (WHERE error_class IS NOT NULL)        AS failed,
    round(avg(latency_ms))                                 AS avg_latency_ms,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms) AS p95_latency_ms,
    sum(bytes)                                             AS bytes,
    sum(battles_count)                                     AS battles,
    sum(new_battles_count)                                 AS new_battles,
    count(*) FILTER (WHERE error_class = 'rate_limited')   AS rate_limited,
    count(*) FILTER (WHERE error_class IN ('timeout', 'network_error')) AS network_failures
FROM public.fetch_log
GROUP BY 1, 2;

-- Possíveis lacunas: a API devolve só as batalhas mais recentes. Se TODAS as batalhas de uma
-- coleta são novas (e não é a primeira coleta do jogador), batalhas antigas podem ter ficado
-- de fora — sinal para aumentar a frequência do cron.
CREATE VIEW monitoring.battle_gaps AS
SELECT
    subject_tag                                   AS player_tag,
    requested_at,
    run_id,
    battles_count,
    new_battles_count
FROM (
    SELECT f.*,
           row_number() OVER (PARTITION BY subject_tag ORDER BY requested_at) AS fetch_number
    FROM public.fetch_log f
    WHERE endpoint = 'battlelog' AND error_class IS NULL AND battles_count IS NOT NULL
) f
WHERE fetch_number > 1
  AND battles_count > 0
  AND new_battles_count = battles_count;

-- Leitura para o Looker Studio: só o schema monitoring, nunca as tabelas.
-- O papel looker_studio_reader é criado uma vez, fora deste script (a senha não fica no git):
--   CREATE ROLE looker_studio_reader LOGIN PASSWORD '...';
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'looker_studio_reader') THEN
        REVOKE USAGE ON SCHEMA public FROM looker_studio_reader;
        GRANT USAGE ON SCHEMA monitoring TO looker_studio_reader;
        GRANT SELECT ON ALL TABLES IN SCHEMA monitoring TO looker_studio_reader;
    END IF;
END $$;
