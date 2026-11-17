# cr-ingest

Ingestão da camada bronze do `battlelog` do Clash Royale: cron → Python → GCS (bruto) + Neon (controle).

## Setup local
```bash
python -m venv .venv && . .venv/bin/activate
pip install -e '.[dev]'
pytest
```

## Passos de implantação
1. `PROJECT=... BUCKET=... ./infra/provision.sh` (cria IP estático, VM e2-micro, bucket com lifecycle).
2. Cadastrar o IP exibido em developer.clashroyale.com.
3. Aplicar `sql/schema.sql` no Neon e inserir 2–3 tags em `players_watchlist`.
4. Na VM: clonar, criar venv, copiar `.env.example` para `.env`, instalar `deploy/crontab.example`.
5. Validar com poucas tags antes de ativar a watchlist completa.

Exit codes: 0 ok · 1 falha parcial · 2 fatal (403, IP não autorizado).
