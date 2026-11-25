-- Custos do projeto (BigQuery). Fonte: exportação "custo de uso padrão" do Cloud Billing.
-- A conta de faturamento paga outros projetos; tudo aqui filtra project.id = 'clash-royale-ingestion'.
-- Aplicar com: bq query --use_legacy_sql=false < sql/costs.bigquery.sql

CREATE SCHEMA IF NOT EXISTS `clash-royale-ingestion.monitoring`
OPTIONS (location = 'US', description = 'Views de custo do projeto para o painel');

-- Custo diário por serviço e SKU, já com créditos (free tier, descontos) abatidos.
-- Colunas com nomes de exibição em inglês, consumidas direto pelo painel do Data Studio.
CREATE OR REPLACE VIEW `clash-royale-ingestion.monitoring.cost_daily` AS
SELECT
    DATE(usage_start_time, 'America/Sao_Paulo')                    AS `Date`,
    service.description                                            AS `Service`,
    sku.description                                                AS `SKU`,
    currency                                                       AS `Currency`,
    SUM(cost)                                                      AS `Gross cost`,
    SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0))  AS `Credits`,
    SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS `Net cost`
FROM `clash-royale-ingestion.billing_export.gcp_billing_export_v1_0153B5_AA2658_4DA0D7`
WHERE project.id = 'clash-royale-ingestion'
GROUP BY 1, 2, 3, 4;

-- Uma linha por moeda: acumulado do mês corrente e acumulado total desde o início da exportação.
CREATE OR REPLACE VIEW `clash-royale-ingestion.monitoring.cost_summary` AS
SELECT
    `Currency`,
    SUM(IF(DATE_TRUNC(`Date`, MONTH) = DATE_TRUNC(CURRENT_DATE('America/Sao_Paulo'), MONTH), `Net cost`, 0))
                                   AS `Month-to-date cost`,
    SUM(`Net cost`)                AS `Total project cost`,
    MIN(`Date`)                    AS `First billed day`,
    MAX(`Date`)                    AS `Last billed day`
FROM `clash-royale-ingestion.monitoring.cost_daily`
GROUP BY `Currency`;
