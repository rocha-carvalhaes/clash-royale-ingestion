# CLAUDE.md

Ingestão da camada bronze do `battlelog` da API do Clash Royale.
Fluxo: cron (VM e2-micro no GCP) → Python → GCS (corpo bruto, gzip) + Neon/Postgres (controle e monitoramento).
Painel de monitoramento no Looker/Data Studio, alimentado por views SQL.

## Comandos

```bash
python -m venv .venv && . .venv/bin/activate
pip install -e '.[dev]'
pytest                                   # testes unitários, sem rede nem banco (usam httpx.MockTransport)
python -m clash_royale_ingestion.main    # uma execução; exige as variáveis do .env.example
```

Exit codes de `main`: `0` sucesso · `1` falha parcial (alguma tag falhou) · `2` fatal (403 = IP de saída não cadastrado na chave da API) ou erro inesperado.

## Estrutura

- `src/clash_royale_ingestion/main.py`: orquestra a execução (`run` → `_ingest`), calcula `RunStats`/status, grava `run_log`, avisa o Healthchecks.io.
- `api.py`: `ClashRoyaleClient` com throttle, retentativas com backoff exponencial (só para erros retentáveis) e `FetchResult`.
- `errors.py`: `classify_status` (HTTP → `error_class`) e `is_retryable`. Valores de `error_class`: `timeout`, `network_error`, `rate_limited`, `forbidden`, `not_found`, `server_error`, `storage_error`, `http_<código>`.
- `storage.py`: `BronzeWriter` grava o corpo como veio (sem reserializar), comprimido, com `if_generation_match=0` (nunca sobrescreve).
- `paths.py`: nome do objeto `bronze/clash_royale/battlelog/dt=YYYY-MM-DD/hr=HH/tag=<TAG>/<fetch_id>.json.gz` (sempre em UTC).
- `repo.py`: acesso ao Postgres (`Repo`), reconexão com retry (`connect_with_retry`) e `battle_stats` (só leitura do corpo para contar batalhas).
- `tags.py`: normalização/codificação de tags (`#ABC` ↔ `%23ABC` na URL, sem `#` no caminho do GCS).
- `healthcheck.py`: pings `/start` e `/<exit_code>` ao Healthchecks.io; falha de rede nunca derruba a ingestão.
- `config.py`: `Config.from_env()`. Variáveis obrigatórias: `CLASH_ROYALE_API_TOKEN`, `NEON_DSN`, `GCS_BUCKET`.
- `sql/schema.sql`: tabelas `players_watchlist`, `fetch_log`, `run_log` (reexecutável; colunas novas via `ADD COLUMN IF NOT EXISTS`).
- `sql/monitoring.sql`: schema `monitoring` no Neon (views `ingestion_status`, `run_summary`, `player_health`, `fetch_daily`, `battle_gaps`), recriadas a cada execução. Aplicar depois de `schema.sql`.
- `sql/costs.bigquery.sql`: views de custo no BigQuery (`monitoring.cost_daily`, `monitoring.cost_summary`), aplicar com `bq query --use_legacy_sql=false`.
- `infra/provision.sh`: IP estático, VM e bucket com lifecycle (Nearline em 30 dias, Coldline em 180).
- `deploy/crontab.example`: cron diário às 06:00 UTC na VM.

## Convenções e decisões

- O dado bruto da API é preservado exatamente como veio. Qualquer contagem ou métrica é derivada por leitura, sem alterar o objeto gravado.
- Falha no GCS não pode apagar o registro da chamada: vira `error_class = storage_error` em `fetch_log`.
- Um 403 aborta a execução inteira (IP não autorizado); as demais falhas contam por tag e resultam em status `partial`.
- `run_log.status`: `running`, `success`, `partial`, `fatal`, `crashed`. Uma linha `running` sem `finished_at` por muito tempo indica execução morta.
- Nas views, colunas em `snake_case` sem abreviação. Os nomes de exibição (ex.: "Duration (s)") ficam nos campos do Data Studio, porque o conector PostgreSQL quebra ao agregar colunas com espaço.
- Views de monitoramento ficam no schema `monitoring`, sem prefixo `vw_`. O papel `looker_studio_reader` lê só esse schema e é criado fora do git (a senha não é versionada).
- Os custos filtram `project.id = 'clash-royale-ingestion'`, pois a conta de faturamento paga outros projetos.
- Código, comentários, mensagens de log e commits são em português; identificadores em inglês.
- Mudanças de schema devem ser aditivas e reexecutáveis (`IF NOT EXISTS`, `OR REPLACE`).

## Segredos

`.env` não é versionado (use `.env.example` como modelo). O DSN do Neon contém `&`, então vai entre aspas simples. Nunca commitar token da API, DSN ou URL de ping do Healthchecks.

## Registro de trabalho

Todo trabalho novo (feature, bug, task, mudança de schema ou infra) é registrado no GitHub Issues: https://github.com/rocha-carvalhaes/clash-royale-ingestion/issues. **O agente é o responsável por esse registro**, usando a skill `registrar-trabalho` (`.claude/skills/registrar-trabalho/SKILL.md`): buscar issue existente, criar ou comentar antes de começar, citar `Refs #n` nos commits e fechar com um comentário de resultado ao concluir. Tipos nativos: `Feature`, `Bug`, `Task`. Labels de área: `area:ingestion`, `area:sql`, `area:monitoring`, `area:costs`, `area:infra`; `data` para mudança de schema ou dados.

## Pendências

A fonte da verdade é a lista de issues abertas, não este arquivo. Ao retomar o trabalho, comece por `list_issues` (estado aberto).
