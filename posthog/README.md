# PostHog self-hosted — Railway Template (HASHING3)

Template Railway para subir **PostHog self-hosted** (analytics de produto open-source) com
deploy 1-clique. Baseado no stack moderno do PostHog, com **object storage em Backblaze B2**.

> **Status: 🚧 Em construção (Fase A).** Esta pasta é o scaffold inicial. A composição do
> template (Dockerfiles pinados, workflow de imagens próprio, `.env.example` documentado e
> `docs/`) é a próxima leva. Este README é placeholder honesto, não o overview final.

## Arquitetura (PostHog moderno — ~22 serviços)

O PostHog atual **não** é o "hobby" de 5 serviços. O stack inclui:

- **App:** `web`, `worker`, `plugins`, `temporal-django-worker`
- **Captura/processamento (Rust/Go):** `capture`, `replay-capture`, `feature-flags`,
  `property-defs-rs`, `cyclotron-janitor`, `cymbal`, `livestream`
- **Dados:** `db` (Postgres), `clickhouse` (OLAP), `redis`
- **Streaming:** `kafka`, `zookeeper`, `kafka-init`
- **Orquestração:** `temporal`
- **Object storage:** Backblaze B2 (camada `OBJECT_STORAGE_*`); MinIO permanece apenas se
  features de IA/DuckLake forem ligadas
- **Proxy:** Caddy

> **Footprint:** ClickHouse + Kafka + Zookeeper + Temporal são *always-on* (não escalam a
> zero). Planeje RAM permanente e custo correspondente.

## Object storage — Backblaze B2

A camada principal (`OBJECT_STORAGE_*` — exports, recordings, query cache) aponta para um
bucket Backblaze B2 (S3-compatible), substituindo o SeaweedFS embarcado. Variáveis:

```
OBJECT_STORAGE_ENABLED=true
OBJECT_STORAGE_ENDPOINT=https://s3.<region>.backblazeb2.com
OBJECT_STORAGE_REGION=<region>
OBJECT_STORAGE_ACCESS_KEY_ID=<b2_application_key_id>
OBJECT_STORAGE_SECRET_ACCESS_KEY=<b2_application_key>
OBJECT_STORAGE_BUCKET=<your-bucket>
```

> **Validação obrigatória:** a compatibilidade S3 do Backblaze com o PostHog moderno
> (multipart/listing usados pelo `replay-capture`) deve passar por **smoke test** (gerar
> export/recording e confirmar o objeto no bucket) antes do uso em produção. Fallback:
> reverter para SeaweedFS via troca das `OBJECT_STORAGE_*`.

## Roadmap de construção

- [x] Scaffold do repositório
- [ ] Dockerfiles pinados (release estável do PostHog) buildando para registry HASHING3
- [ ] Workflow de imagens próprio (tags imutáveis)
- [ ] `.env.example` completo + `docs/` (setup, operação, custo, contingência storage)
- [ ] Composição e publicação do template na Railway + smoke test do object storage
