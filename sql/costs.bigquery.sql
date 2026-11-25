-- Custos do projeto (BigQuery). Fonte: exportação "custo de uso padrão" do Cloud Billing.
-- A conta de faturamento paga outros projetos; tudo aqui filtra project.id = 'clash-royale-ingestion'.
-- Aplicar com: bq query --use_legacy_sql=false < sql/costs.bigquery.sql

CREATE SCHEMA IF NOT EXISTS `clash-royale-ingestion.monitoring`
OPTIONS (location = 'US', description = 'Views de custo do projeto para o painel');

-- Custo diário por serviço e SKU, já com créditos (free tier, descontos) abatidos.
-- Colunas em snake_case; os nomes de exibição ficam nos campos das fontes do Data Studio.
CREATE OR REPLACE VIEW `clash-royale-ingestion.monitoring.cost_daily` AS
SELECT
    DATE(usage_start_time, 'America/Sao_Paulo')                    AS date,
    service.description                                            AS service,
    sku.description                                                AS sku,
    currency                                                       AS currency,
    SUM(cost)                                                      AS gross_cost,
    SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0))  AS credits,
    SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net_cost
FROM `clash-royale-ingestion.billing_export.gcp_billing_export_v1_0153B5_AA2658_4DA0D7`
WHERE project.id = 'clash-royale-ingestion'
GROUP BY 1, 2, 3, 4;

-- Uma linha por moeda: acumulado do mês corrente e acumulado total desde o início da exportação.
CREATE OR REPLACE VIEW `clash-royale-ingestion.monitoring.cost_summary` AS
SELECT
    currency,
    SUM(IF(DATE_TRUNC(date, MONTH) = DATE_TRUNC(CURRENT_DATE('America/Sao_Paulo'), MONTH), net_cost, 0))
                                   AS month_to_date_cost,
    SUM(net_cost)                AS total_project_cost,
    MIN(date)                    AS first_billed_day,
    MAX(date)                    AS last_billed_day
FROM `clash-royale-ingestion.monitoring.cost_daily`
GROUP BY currency;
