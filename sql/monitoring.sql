-- Views de saúde e volumetria da ingestão, consumidas pelo painel do Data Studio.
-- São a camada de apresentação: colunas e valores já com nomes de exibição em inglês
-- ("Net cost", "Duration (s)"), para o painel não precisar renomear campo nenhum.
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
    END                                                              AS "Health",
    monitoring.run_status_label(r.status)                            AS "Last run status",
    r.started_at                                                     AS "Last run at",
    r.tags_ok                                                        AS "Players collected",
    r.tags_total                                                     AS "Players expected",
    r.new_battles_total                                              AS "New battles",
    s.last_success_at                                                AS "Last success at",
    round(extract(epoch FROM now() - s.last_success_at) / 3600, 1)   AS "Hours since last success",
    r.error_message                                                  AS "Last error",
    r.run_id                                                         AS "Run ID"
FROM (SELECT * FROM public.run_log ORDER BY started_at DESC LIMIT 1) r
CROSS JOIN (SELECT max(finished_at) AS last_success_at FROM public.run_log
            WHERE status IN ('success', 'partial')) s;

-- Histórico de execuções.
CREATE VIEW monitoring.run_summary AS
SELECT
    started_at                                                       AS "Started at",
    (started_at AT TIME ZONE 'America/Sao_Paulo')::date              AS "Date",
    monitoring.run_status_label(status)                              AS "Status",
    round(extract(epoch FROM finished_at - started_at)::numeric, 1)  AS "Duration (s)",
    tags_total                                                       AS "Players expected",
    tags_ok                                                          AS "Players collected",
    tags_failed                                                      AS "Players failed",
    battles_total                                                    AS "Battles fetched",
    new_battles_total                                                AS "New battles",
    round(bytes_total / 1048576.0, 2)                                AS "Data (MB)",
    error_message                                                    AS "Error",
    host                                                             AS "Host",
    run_id                                                           AS "Run ID"
FROM public.run_log;

-- Situação de cada jogador da watchlist.
CREATE VIEW monitoring.player_health AS
SELECT
    w.player_tag                                                     AS "Player tag",
    CASE WHEN w.is_active THEN 'Active' ELSE 'Paused' END            AS "Tracking",
    w.last_fetched_at                                                AS "Last fetched at",
    w.last_battle_at                                                 AS "Last battle at",
    round(extract(epoch FROM now() - w.last_battle_at) / 86400, 1)   AS "Days since last battle",
    CASE WHEN last_fetch.error_class IS NULL THEN 'OK'
         ELSE initcap(replace(last_fetch.error_class, '_', ' ')) END AS "Last fetch result",
    coalesce(recent.fetches_7d, 0)                                   AS "Fetches (7 days)",
    coalesce(recent.failures_7d, 0)                                  AS "Failures (7 days)"
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
    (requested_at AT TIME ZONE 'America/Sao_Paulo')::date            AS "Date",
    initcap(endpoint)                                                AS "Endpoint",
    count(*)                                                         AS "API calls",
    count(*) FILTER (WHERE error_class IS NULL)                      AS "Successful calls",
    count(*) FILTER (WHERE error_class IS NOT NULL)                  AS "Failed calls",
    count(*) FILTER (WHERE error_class = 'rate_limited')             AS "Rate-limited calls",
    count(*) FILTER (WHERE error_class IN ('timeout', 'network_error')) AS "Network failures",
    round(avg(latency_ms))                                           AS "Average latency (ms)",
    round(percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)::numeric) AS "95th percentile latency (ms)",
    round(coalesce(sum(bytes), 0) / 1048576.0, 2)                    AS "Data (MB)",
    sum(battles_count)                                               AS "Battles fetched",
    sum(new_battles_count)                                           AS "New battles"
FROM public.fetch_log
GROUP BY 1, 2;

-- Possíveis lacunas: a API devolve só as batalhas mais recentes. Se TODAS as batalhas de uma
-- coleta são novas (e não é a primeira coleta do jogador), batalhas antigas podem ter ficado
-- de fora — sinal para aumentar a frequência do cron.
CREATE VIEW monitoring.battle_gaps AS
SELECT
    subject_tag                                                      AS "Player tag",
    requested_at                                                     AS "Fetched at",
    battles_count                                                    AS "Battles fetched",
    new_battles_count                                                AS "New battles",
    run_id                                                           AS "Run ID"
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
