-- Views de saúde e volumetria da ingestão, consumidas pelo painel do Data Studio.
-- Nomes de coluna em snake_case sem abreviação; os nomes de exibição ("Duration (s)") ficam nos
-- campos das fontes do Data Studio: o conector PostgreSQL quebra ao agregar colunas com espaço.
-- Aplicar depois de schema.sql. Reexecutável: as views são recriadas.

CREATE SCHEMA IF NOT EXISTS monitoring;

-- Nomes antigos (prefixo vw_ em public), removidos na migração para o schema monitoring.
DROP VIEW IF EXISTS public.vw_ingestion_status, public.vw_run_summary, public.vw_player_health,
                    public.vw_fetch_daily, public.vw_battle_gaps;

DROP VIEW IF EXISTS monitoring.ingestion_status, monitoring.run_summary, monitoring.player_health,
                    monitoring.fetch_daily, monitoring.battle_gaps;

-- Rótulo de exibição do status de uma execução.
CREATE OR REPLACE FUNCTION monitoring.run_status_label(status text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE status
        WHEN 'success' THEN 'Success'
        WHEN 'partial' THEN 'Partial'
        WHEN 'fatal'   THEN 'Failed'
        WHEN 'crashed' THEN 'Crashed'
        WHEN 'running' THEN 'Running'
        ELSE initcap(status)
    END
$$;

-- Uma linha: a situação atual, para o topo do painel.
CREATE VIEW monitoring.ingestion_status AS
SELECT
    CASE
        WHEN s.last_success_at IS NULL OR now() - s.last_success_at > interval '26 hours' THEN 'Overdue'
        WHEN r.status IN ('fatal', 'crashed') THEN 'Failing'
        WHEN r.status = 'partial' THEN 'Degraded'
        ELSE 'Healthy'
    END                                                              AS health,
    monitoring.run_status_label(r.status)                            AS last_run_status,
    r.started_at                                                     AS last_run_at,
    r.tags_ok                                                        AS players_collected,
    r.tags_total                                                     AS players_expected,
    r.new_battles_total                                              AS new_battles,
    s.last_success_at                                                AS last_success_at,
    round(extract(epoch FROM now() - s.last_success_at) / 3600, 1)   AS hours_since_last_success,
    r.error_message                                                  AS last_error,
    r.run_id                                                         AS run_id
FROM (SELECT * FROM public.run_log ORDER BY started_at DESC LIMIT 1) r
CROSS JOIN (SELECT max(finished_at) AS last_success_at FROM public.run_log
            WHERE status IN ('success', 'partial')) s;

-- Histórico de execuções.
CREATE VIEW monitoring.run_summary AS
SELECT
    started_at                                                       AS started_at,
    (started_at AT TIME ZONE 'America/Sao_Paulo')::date              AS date,
    monitoring.run_status_label(status)                              AS status,
    round(extract(epoch FROM finished_at - started_at)::numeric, 1)  AS duration_seconds,
    tags_total                                                       AS players_expected,
    tags_ok                                                          AS players_collected,
    tags_failed                                                      AS players_failed,
    battles_total                                                    AS battles_fetched,
    new_battles_total                                                AS new_battles,
    round(bytes_total / 1048576.0, 2)                                AS data_megabytes,
    error_message                                                    AS error,
    host                                                             AS host,
    run_id                                                           AS run_id
FROM public.run_log;

-- Situação de cada jogador da watchlist.
CREATE VIEW monitoring.player_health AS
SELECT
    w.player_tag                                                     AS player_tag,
    CASE WHEN w.is_active THEN 'Active' ELSE 'Paused' END            AS tracking,
    w.last_fetched_at                                                AS last_fetched_at,
    w.last_battle_at                                                 AS last_battle_at,
    round(extract(epoch FROM now() - w.last_battle_at) / 86400, 1)   AS days_since_last_battle,
    CASE WHEN last_fetch.error_class IS NULL THEN 'OK'
         ELSE initcap(replace(last_fetch.error_class, '_', ' ')) END AS last_fetch_result,
    coalesce(recent.fetches_7d, 0)                                   AS fetches_last_7_days,
    coalesce(recent.failures_7d, 0)                                  AS failures_last_7_days
FROM public.players_watchlist w
LEFT JOIN LATERAL (
    SELECT error_class FROM public.fetch_log f
    WHERE f.subject_tag = w.player_tag AND f.endpoint = 'battlelog'
    ORDER BY requested_at DESC LIMIT 1
) last_fetch ON true
LEFT JOIN LATERAL (
    SELECT count(*) AS fetches_7d, count(*) FILTER (WHERE error_class IS NOT NULL) AS failures_7d
    FROM public.fetch_log f
    WHERE f.subject_tag = w.player_tag AND f.requested_at > now() - interval '7 days'
) recent ON true;

-- Agregado diário das chamadas à API, para os gráficos de tendência.
CREATE VIEW monitoring.fetch_daily AS
SELECT
    (requested_at AT TIME ZONE 'America/Sao_Paulo')::date            AS date,
    initcap(endpoint)                                                AS endpoint,
    count(*)                                                         AS api_calls,
    count(*) FILTER (WHERE error_class IS NULL)                      AS successful_calls,
    count(*) FILTER (WHERE error_class IS NOT NULL)                  AS failed_calls,
    count(*) FILTER (WHERE error_class = 'rate_limited')             AS rate_limited_calls,
    count(*) FILTER (WHERE error_class IN ('timeout', 'network_error')) AS network_failures,
    round(avg(latency_ms))                                           AS average_latency_milliseconds,
    round(percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)::numeric) AS percentile_95_latency_milliseconds,
    round(coalesce(sum(bytes), 0) / 1048576.0, 2)                    AS data_megabytes,
    sum(battles_count)                                               AS battles_fetched,
    sum(new_battles_count)                                           AS new_battles
FROM public.fetch_log
GROUP BY 1, 2;

-- Possíveis lacunas: a API devolve só as batalhas mais recentes. Se TODAS as batalhas de uma
-- coleta são novas (e não é a primeira coleta do jogador), batalhas antigas podem ter ficado
-- de fora — sinal para aumentar a frequência do cron.
CREATE VIEW monitoring.battle_gaps AS
SELECT
    subject_tag                                                      AS player_tag,
    requested_at                                                     AS fetched_at,
    battles_count                                                    AS battles_fetched,
    new_battles_count                                                AS new_battles,
    run_id                                                           AS run_id
FROM (
    SELECT f.*,
           row_number() OVER (PARTITION BY subject_tag ORDER BY requested_at) AS fetch_number
    FROM public.fetch_log f
    WHERE endpoint = 'battlelog' AND error_class IS NULL AND battles_count IS NOT NULL
) f
WHERE fetch_number > 1
  AND battles_count > 0
  AND new_battles_count = battles_count;

-- Leitura para o Data Studio: só o schema monitoring, nunca as tabelas.
-- O papel looker_studio_reader é criado uma vez, fora deste script (a senha não fica no git):
--   CREATE ROLE looker_studio_reader LOGIN PASSWORD '...';
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'looker_studio_reader') THEN
        REVOKE USAGE ON SCHEMA public FROM looker_studio_reader;
        GRANT USAGE ON SCHEMA monitoring TO looker_studio_reader;
        GRANT SELECT ON ALL TABLES IN SCHEMA monitoring TO looker_studio_reader;
        GRANT EXECUTE ON FUNCTION monitoring.run_status_label(text) TO looker_studio_reader;
    END IF;
END $$;
