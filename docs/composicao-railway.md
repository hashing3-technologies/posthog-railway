# Runbook de composição na Railway

> **Template:** PostHog self-hosted da HASHING3
> **Imagens:** `ghcr.io/hashing3-technologies/posthog-railway/<serviço>:9373a2b55081d3e711ad58bca060a6a9ab5d41a5`
> **Fonte da verdade:** `docker-compose.hobby.yml` + `docker-compose.base.yml` do PostHog no commit `9373a2b55081d3e711ad58bca060a6a9ab5d41a5` (anchors do base resolvidos contra o hobby).
> **Object storage:** 100% Backblaze B2 (S3-compatible). Os serviços `objectstorage` (MinIO) e `seaweedfs` do compose oficial **não são incluídos**; todo endpoint que apontava para `objectstorage:19000` ou `seaweedfs:8333` foi trocado por B2.

Legenda rápida:
- **GHCR** = GitHub Container Registry. Aqui sob a org `hashing3-technologies`.
- **B2** = Backblaze B2 (object storage compatível com S3).
- **`[confirmar]`** = item que dependia de arquivo do repo; a seção final consolida quais foram resolvidos (estão embutidos nas imagens) e quais são decisão de deploy.

---

## Como adicionar um serviço na Railway

1. No projeto Railway: **New Service → Deploy from Docker Image**.
2. Imagem: `ghcr.io/hashing3-technologies/posthog-railway/<serviço>:9373a2b55081d3e711ad58bca060a6a9ab5d41a5` (a Railway **puxa** a imagem pronta; não builda Dockerfile).
3. Nomeie o serviço **exatamente** com o nome canônico (ex.: `clickhouse`, `db`, `kafka`, `redis7`, `zookeeper`, `temporal`). Esse nome é o hostname interno usado pelas env vars (ex.: `postgres://posthog:posthog@db:5432/posthog`).
4. Cole as env vars da subseção do serviço.
5. Para serviços com estado, anexe um **Volume** no mountpath indicado.

> **Pré-requisito:** os 19 packages no GHCR precisam estar **públicos** (senão a Railway não puxa sem credencial de registry).

### Ordem geral de boot

Railway não tem `depends_on` real; respeite a ordem ao criar/subir. A maioria dos serviços tem `restart: on-failure`, então reconectam quando a dependência aparece:

```
1. Infra base:   db, clickhouse, redis7, zookeeper
2. Mensageria:   kafka            (depende de zookeeper)
3. Bootstrap:    kafka-init       (cria tópicos; depende de kafka saudável)
4. Orquestração: temporal         (depende de db)
5. App Django:   web → worker → plugins → temporal-django-worker
6. Rust/serviços: capture, replay-capture, property-defs-rs, cyclotron-janitor,
                  cymbal, feature-flags, livestream
7. Edge:         proxy            (depende de web + livestream)
```

---

## db (Postgres)

- **Imagem:** `.../db:9373a2b...` *(upstream `postgres:15.12-alpine`)*
- **Env:**
```env
POSTGRES_USER=posthog
POSTGRES_DB=posthog
POSTGRES_PASSWORD=posthog
```
- **Volume:** `postgres-data` → `/var/lib/postgresql/data`
- **Portas:** `5432`
- **depends_on:** nenhum (infra base). Healthcheck: `pg_isready -U posthog`.

## redis7

- **Imagem:** `.../redis7:9373a2b...` *(upstream `redis:7.2-alpine`)*
- **Command (já na imagem):** `redis-server --maxmemory-policy allkeys-lru --maxmemory 200mb`
- **Env:** nenhuma.
- **Volume:** `redis7-data` → `/data`
- **Portas:** `6379`
- **depends_on:** nenhum.

## clickhouse

- **Imagem:** `.../clickhouse:9373a2b...` *(upstream `clickhouse/clickhouse-server:25.8.12.129`)*
- **Env:**
```env
CLICKHOUSE_SKIP_USER_SETUP=1
KAFKA_HOSTS=kafka:9092
```
- **Volume:** `clickhouse-data` → `/var/lib/clickhouse`. Os configs/IDL/scripts (config.xml, users.xml, default.xml, user_defined_function.xml, IDL, initdb, user_scripts) **já estão embutidos na imagem** (COPY no build) — não precisa montar do repo.
- **Portas:** `9000` (nativo), `8123` (HTTP)
- **depends_on:** `kafka`, `zookeeper`

## zookeeper

- **Imagem:** `.../zookeeper:9373a2b...` *(upstream `zookeeper:3.7.0`)*
- **Env:** nenhuma.
- **Volumes:** `zookeeper-data`→`/data`, `zookeeper-datalog`→`/datalog`, `zookeeper-logs`→`/logs`
- **Portas:** `2181` (client)
- **depends_on:** nenhum.

## kafka

> Imagem real: **Redpanda** (fala protocolo Kafka). Hostname `kafka`.

- **Imagem:** `.../kafka:9373a2b...` *(upstream `redpandadata/redpanda:v25.1.9`)*
- **Command (já na imagem base):** `redpanda start ...` com `--advertise-kafka-addr internal://kafka:9092`, `--rpc-addr kafka:33145`, `--seeds kafka:33145`, `--set redpanda.auto_create_topics_enabled=true` (ver `docker-compose.base.yml` para o command completo).
- **Env:**
```env
ALLOW_PLAINTEXT_LISTENER=true
KAFKA_LOG_RETENTION_MS=3600000
KAFKA_LOG_RETENTION_CHECK_INTERVAL_MS=300000
KAFKA_LOG_RETENTION_HOURS=1
```
- **Volume:** `kafka-data` → **`/var/lib/redpanda/data`** (a imagem é Redpanda; este é o diretório de dados real. O `/bitnami/kafka` do compose hobby é legado do `bitnami/kafka` e não se aplica ao Redpanda).
- **Portas:** `9092` (Kafka), `8082` (pandaproxy), `8081` (schema registry), `33145` (RPC), `9644` (admin/health). Healthcheck: `curl -f http://localhost:9644/v1/status/ready`.
- **depends_on:** `zookeeper`

## kafka-init

> Job efêmero (one-shot): cria os tópicos `exceptions_ingestion` e `clickhouse_events_json` e encerra. Na Railway, rode como serviço que sai após concluir (ou job manual; pode acusar "crash" ao terminar — é esperado).

- **Imagem:** `.../kafka-init:9373a2b...` *(upstream Redpanda; entrypoint próprio)*
- **Command (já na imagem):** espera `kafka:9092` e cria os 2 tópicos (`-p 1 -r 1`).
- **Env / Volume / Portas:** nenhum.
- **depends_on:** `kafka` (saudável)

## temporal

- **Imagem:** `.../temporal:9373a2b...` *(upstream `temporalio/auto-setup:1.20.0`)*
- **Env:**
```env
DB=postgresql
DB_PORT=5432
POSTGRES_USER=posthog
POSTGRES_PWD=posthog
POSTGRES_SEEDS=db
DYNAMIC_CONFIG_FILE_PATH=config/dynamicconfig/development-sql.yaml
ENABLE_ES=false
```
> `ENABLE_ES=false` (override do hobby) desliga o Elasticsearch — coerente com **não** incluir `elasticsearch`/`temporal-ui`/`temporal-admin-tools`.
- **Volume:** nenhum. O `development-sql.yaml` (dynamicconfig) **já está embutido na imagem** (COPY no build).
- **Portas:** `7233` (gRPC)
- **depends_on:** `db` (saudável)

## web

> Django/PostHog principal. Herda o anchor `*worker_env` do base; o hobby adiciona o bloco abaixo.

- **Imagem:** `.../web:9373a2b...`
- **Command (já na imagem):** `/compose/start` (embutido).
- **Env:**
```env
# herdado do anchor *worker_env (base)
OTEL_SDK_DISABLED=true
DISABLE_SECURE_SSL_REDIRECT=true
IS_BEHIND_PROXY=true
DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
CLICKHOUSE_HOST=clickhouse
CLICKHOUSE_DATABASE=posthog
CLICKHOUSE_SECURE=false
CLICKHOUSE_VERIFY=false
CLICKHOUSE_API_USER=api
CLICKHOUSE_API_PASSWORD=apipass
CLICKHOUSE_APP_USER=app
CLICKHOUSE_APP_PASSWORD=apppass
API_QUERIES_PER_TEAM={"1": 100}
KAFKA_HOSTS=kafka
REDIS_URL=redis://redis7:6379/
PGHOST=db
PGUSER=posthog
PGPASSWORD=posthog
DEPLOYMENT=hobby
CDP_API_URL=http://plugins:6738
FLAGS_REDIS_ENABLED=false
# bloco do hobby (web)
SITE_URL=https://<DOMAIN>
LIVESTREAM_HOST=https://<DOMAIN>/livestream
SECRET_KEY=<POSTHOG_SECRET>
ENCRYPTION_SALT_KEYS=<ENCRYPTION_SALT_KEYS>
USE_GRANIAN=true
GRANIAN_WORKERS=2
OPT_OUT_CAPTURE=false
# storage → Backblaze B2 (ver seção final)
OBJECT_STORAGE_ENABLED=true
OBJECT_STORAGE_ENDPOINT=https://s3.<region>.backblazeb2.com
OBJECT_STORAGE_ACCESS_KEY_ID=<b2_application_key_id>
OBJECT_STORAGE_SECRET_ACCESS_KEY=<b2_application_key>
SESSION_RECORDING_V2_S3_ENDPOINT=https://s3.<region>.backblazeb2.com
SESSION_RECORDING_V2_S3_ACCESS_KEY_ID=<b2_application_key_id>
SESSION_RECORDING_V2_S3_SECRET_ACCESS_KEY=<b2_application_key>
```
- **Volume:** nenhum.
- **Portas:** `8000`
- **depends_on:** `db`, `redis7`, `clickhouse`, `kafka`

## worker

> Celery worker + scheduler. Herda `*worker_env`.

- **Imagem:** `.../worker:9373a2b...`
- **Command (já na imagem):** `./bin/docker-worker-celery --with-scheduler`
- **Env:** todo o anchor `*worker_env` (idêntico ao de `web`) +:
```env
SITE_URL=https://<DOMAIN>
SECRET_KEY=<POSTHOG_SECRET>
ENCRYPTION_SALT_KEYS=<ENCRYPTION_SALT_KEYS>
OBJECT_STORAGE_ENABLED=true
POSTHOG_SKIP_MIGRATION_CHECKS=1
# storage → B2 (OBJECT_STORAGE_* + SESSION_RECORDING_V2_S3_*, idem web)
```
- **Volume:** nenhum. **Portas:** nenhuma.
- **depends_on:** `db`, `redis7`, `clickhouse`, `kafka`, `web`

## plugins

> Ingestion / CDP. Webhooks na porta `6738`.

- **Imagem:** `.../plugins:9373a2b...`
- **Command (já na imagem):** `./bin/posthog-node --no-restart-loop`
- **Env:**
```env
DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
PERSONS_DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
BEHAVIORAL_COHORTS_DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
CYCLOTRON_DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
KAFKA_HOSTS=kafka:9092
REDIS_URL=redis://redis7:6379/
CLICKHOUSE_HOST=clickhouse
CLICKHOUSE_DATABASE=posthog
CLICKHOUSE_SECURE=false
CLICKHOUSE_VERIFY=false
COOKIELESS_REDIS_HOST=redis7
COOKIELESS_REDIS_PORT=6379
CDP_REDIS_HOST=redis7
CDP_REDIS_PORT=6379
LOGS_REDIS_HOST=redis7
LOGS_REDIS_PORT=6379
LOGS_REDIS_TLS=false
SITE_URL=https://<DOMAIN>
SECRET_KEY=<POSTHOG_SECRET>
ENCRYPTION_SALT_KEYS=<ENCRYPTION_SALT_KEYS>
OBJECT_STORAGE_ENABLED=true
SESSION_RECORDING_V2_S3_TIMEOUT_MS=120000
# storage → B2 (OBJECT_STORAGE_* + SESSION_RECORDING_V2_S3_*, idem web)
```
> `KAFKA_HOSTS=kafka:9092` aqui (com porta), diferente do anchor Django (`kafka`).
- **Volume:** nenhum. **Portas:** `6738` (webhooks).
- **depends_on:** `db`, `redis7`, `clickhouse`, `kafka`

## temporal-django-worker

- **Imagem:** `.../temporal-django-worker:9373a2b...`
- **Command (já na imagem):** `/compose/temporal-django-worker`
- **Env:** anchor `*worker_env` (idem web) +:
```env
TEMPORAL_HOST=temporal
SITE_URL=https://<DOMAIN>
SECRET_KEY=<POSTHOG_SECRET>
```
- **Volume:** nenhum. **Portas:** nenhuma.
- **depends_on:** `db`, `redis7`, `clickhouse`, `kafka`, `temporal`

## capture

- **Imagem:** `.../capture:9373a2b...`
- **Env:**
```env
ADDRESS=0.0.0.0:3000
KAFKA_TOPIC=events_plugin_ingestion
KAFKA_HOSTS=kafka:9092
REDIS_URL=redis://redis7:6379/
CAPTURE_MODE=events
RUST_LOG=info,rdkafka=warn
```
- **Volume:** nenhum. **Portas:** `3000`.
- **depends_on (lógico):** `kafka`, `redis7`

## replay-capture

> Mesma imagem do `capture`, modo `recordings`.

- **Imagem:** `.../replay-capture:9373a2b...`
- **Env:**
```env
ADDRESS=0.0.0.0:3000
KAFKA_TOPIC=session_recording_snapshot_item_events
KAFKA_HOSTS=kafka:9092
REDIS_URL=redis://redis7:6379/
CAPTURE_MODE=recordings
```
- **Volume:** nenhum. **Portas:** `3000`.
- **depends_on (lógico):** `kafka`, `redis7`

## cyclotron-janitor

- **Imagem:** `.../cyclotron-janitor:9373a2b...`
- **Env (merge efetivo hobby sobre base):**
```env
DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
KAFKA_HOSTS=kafka:9092
KAFKA_TOPIC=clickhouse_app_metrics2
```
> O hobby aponta `DATABASE_URL` para o banco `posthog` (não um banco `cyclotron` separado).
- **Volume:** nenhum. **Portas:** nenhuma.
- **depends_on:** `db`, `kafka`

## cymbal

> Error tracking (Rust). Usa storage B2.

- **Imagem:** `.../cymbal:9373a2b...`
- **Env:**
```env
KAFKA_HOSTS=kafka:9092
KAFKA_CONSUMER_GROUP=cymbal
KAFKA_CONSUMER_TOPIC=exceptions_ingestion
DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
PERSONS_URL=postgres://posthog:posthog@db:5432/posthog
MAXMIND_DB_PATH=/share/GeoLite2-City.mmdb
REDIS_URL=redis://redis7:6379/
ISSUE_BUCKETS_REDIS_URL=redis://redis7:6379/
RUST_LOG=info
BIND_HOST=0.0.0.0
BIND_PORT=3302
# storage → B2 (era http://seaweedfs:8333)
OBJECT_STORAGE_BUCKET=<bucket>
OBJECT_STORAGE_ENDPOINT=https://s3.<region>.backblazeb2.com
OBJECT_STORAGE_ACCESS_KEY_ID=<b2_application_key_id>
OBJECT_STORAGE_SECRET_ACCESS_KEY=<b2_application_key>
OBJECT_STORAGE_FORCE_PATH_STYLE=true
```
- **Volume:** nenhum. O `GeoLite2-City.mmdb` em `/share` **já está embutido na imagem** (COPY no build).
- **Portas:** `3302`.
- **depends_on:** `kafka-init` (concluído), `db`, `redis7`

## feature-flags

- **Imagem:** `.../feature-flags:9373a2b...`
- **Env:**
```env
WRITE_DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
READ_DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
PERSONS_WRITE_DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
PERSONS_READ_DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
MAXMIND_DB_PATH=/share/GeoLite2-City.mmdb
REDIS_URL=redis://redis7:6379/
ADDRESS=0.0.0.0:3001
RUST_LOG=info
COOKIELESS_REDIS_HOST=redis7
COOKIELESS_REDIS_PORT=6379
```
- **Volume:** nenhum. GeoLite2 `/share` **embutido na imagem**.
- **Portas:** `3001`.
- **depends_on:** `db`, `redis7`

## livestream

> Go, eventos em tempo real. Porta `8080`.

- **Imagem:** `.../livestream:9373a2b...`
- **Env:**
```env
LIVESTREAM_JWT_SECRET=<POSTHOG_SECRET>
```
> = mesmo `$POSTHOG_SECRET` do `SECRET_KEY`.
- **Volume:** nenhum. O `configs.yml` em `/configs/configs.yml` **já está embutido na imagem** (COPY no build).
- **Portas:** `8080`.
- **depends_on:** `kafka`

## property-defs-rs

- **Imagem:** `.../property-defs-rs:9373a2b...`
- **Env:**
```env
DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
KAFKA_HOSTS=kafka:9092
SKIP_WRITES=false
SKIP_READS=false
FILTER_MODE=opt-out
```
- **Volume:** nenhum. **Portas:** nenhuma declarada.
- **depends_on:** `kafka-init` (concluído), `db`

## proxy (Caddy)

> Roteamento HTTP/TLS. **Decisão de arquitetura pendente** (ver seção final): na Railway pode-se terminar TLS no edge nativo e usar o roteamento da plataforma em vez do Caddy. Se mantido, os upstreams do Caddyfile (`web:8000`, `capture:3000`, `replay-capture:3000`, `feature-flags:3001`, `plugins:6738`, `livestream:8080`) batem com os serviços deste runbook.

- **Imagem:** `.../proxy:9373a2b...` *(upstream `caddy:2-alpine`)*
- **Env:**
```env
CADDY_TLS_BLOCK=<TLS_BLOCK>
CADDY_HOST=<DOMAIN>, http://, https://
CADDYFILE=<template Caddy completo — vem do base>
```
- **Volumes:** `caddy-data`→`/data`, `caddy-config`→`/config`
- **Portas:** `80`, `443`
- **depends_on:** `web`, `livestream`

---

## Variáveis compartilhadas / storage B2

### Postgres
```env
DATABASE_URL=postgres://posthog:posthog@db:5432/posthog   # quase todos os serviços
POSTGRES_USER=posthog
POSTGRES_DB=posthog
POSTGRES_PASSWORD=posthog
PGHOST=db
PGUSER=posthog
PGPASSWORD=posthog
```
> Em produção troque a senha `posthog` por um segredo forte e propague em **todas** as connection strings simultaneamente.

### ClickHouse (anchor `*worker_env`)
```env
CLICKHOUSE_HOST=clickhouse
CLICKHOUSE_DATABASE=posthog
CLICKHOUSE_SECURE=false
CLICKHOUSE_VERIFY=false
CLICKHOUSE_API_USER=api
CLICKHOUSE_API_PASSWORD=apipass
CLICKHOUSE_APP_USER=app
CLICKHOUSE_APP_PASSWORD=apppass
```

### Kafka — DOIS formatos (não unificar)
```env
KAFKA_HOSTS=kafka         # serviços Django via anchor (web, worker, temporal-django-worker)
KAFKA_HOSTS=kafka:9092    # Rust + plugins + clickhouse (capture, replay-capture, property-defs-rs, cyclotron-janitor, cymbal)
```

### Redis
```env
REDIS_URL=redis://redis7:6379/
COOKIELESS_REDIS_HOST=redis7   # plugins, feature-flags
COOKIELESS_REDIS_PORT=6379
```

### Segredos da aplicação
```env
SECRET_KEY=<POSTHOG_SECRET>                    # web, worker, plugins, temporal-django-worker
ENCRYPTION_SALT_KEYS=<ENCRYPTION_SALT_KEYS>    # web, worker, plugins
LIVESTREAM_JWT_SECRET=<POSTHOG_SECRET>         # livestream (= mesmo POSTHOG_SECRET)
SITE_URL=https://<DOMAIN>                      # web, worker, plugins, temporal-django-worker
```
> Gere `POSTHOG_SECRET` (`openssl rand -hex 32`) e `ENCRYPTION_SALT_KEYS` (`openssl rand -hex 16`).

### Storage → Backblaze B2 (substitui MinIO/SeaweedFS)

Aplique nos serviços que usam storage: **web**, **worker**, **plugins** (`OBJECT_STORAGE_*` + `SESSION_RECORDING_V2_S3_*`) e **cymbal** (`OBJECT_STORAGE_*` com bucket + path-style). Todos apontam pro **mesmo** B2.

```env
OBJECT_STORAGE_ENABLED=true
OBJECT_STORAGE_ENDPOINT=https://s3.<region>.backblazeb2.com
OBJECT_STORAGE_REGION=<region>                 # ex.: us-west-004
OBJECT_STORAGE_ACCESS_KEY_ID=<b2_application_key_id>
OBJECT_STORAGE_SECRET_ACCESS_KEY=<b2_application_key>
OBJECT_STORAGE_BUCKET=<bucket>
OBJECT_STORAGE_FORCE_PATH_STYLE=true
SESSION_RECORDING_V2_S3_ENDPOINT=https://s3.<region>.backblazeb2.com
SESSION_RECORDING_V2_S3_REGION=<region>
SESSION_RECORDING_V2_S3_ACCESS_KEY_ID=<b2_application_key_id>
SESSION_RECORDING_V2_S3_SECRET_ACCESS_KEY=<b2_application_key>
SESSION_RECORDING_V2_S3_BUCKET=<bucket>
SESSION_RECORDING_V2_S3_TIMEOUT_MS=120000
```

Mapa de substituição (compose original → B2):

| Variável | Era | Vira (B2) |
|---|---|---|
| `OBJECT_STORAGE_ENDPOINT` | `http://objectstorage:19000` | `https://s3.<region>.backblazeb2.com` |
| `OBJECT_STORAGE_ACCESS_KEY_ID` | `object_storage_root_user` | `<b2_application_key_id>` |
| `OBJECT_STORAGE_SECRET_ACCESS_KEY` | `object_storage_root_password` | `<b2_application_key>` |
| `SESSION_RECORDING_V2_S3_ENDPOINT` | `http://seaweedfs:8333` | `https://s3.<region>.backblazeb2.com` |
| `SESSION_RECORDING_V2_S3_*` keys | `any` / `any` | `<b2_application_key_id>` / `<b2_application_key>` |
| `OBJECT_STORAGE_ENDPOINT` (cymbal) | `http://seaweedfs:8333` | `https://s3.<region>.backblazeb2.com` |

---

## Resolução dos itens `[confirmar]`

**Resolvidos** (verificado nos Dockerfiles deste repo — os arquivos estão **embutidos nas imagens** via `COPY` no build, não precisam de bind mount/volume na Railway):

- **clickhouse** — config.xml, users.xml, default.xml, user_defined_function.xml, IDL, initdb, user_scripts → embutidos.
- **temporal** — `development-sql.yaml` (dynamicconfig) → embutido.
- **web / temporal-django-worker** — scripts `/compose/start` e `/compose/temporal-django-worker` → embutidos.
- **cymbal / feature-flags** — `GeoLite2-City.mmdb` em `/share` → embutido.
- **livestream** — `configs.yml` → embutido.
- **kafka volume** — corrigido para `/var/lib/redpanda/data` (a imagem é Redpanda; `/bitnami/kafka` do hobby é legado e não se aplica).

**Decisões de deploy (sua chamada):**

1. **B2 bucket/region** — `web/worker/plugins` não recebem bucket/region explícitos no compose (só `cymbal`). Defina `OBJECT_STORAGE_BUCKET` + `OBJECT_STORAGE_REGION` no deploy; use o mesmo bucket para todos.
2. **proxy / Caddy vs roteamento nativo da Railway** — o Caddy termina TLS e roteia. Na Railway o edge já faz TLS; avaliar manter o Caddy (roteamento interno por path) **ou** expor `web`/`capture`/`replay-capture`/`feature-flags`/`plugins`/`livestream` via domínios/rotas nativas. Decisão de arquitetura antes de publicar.
3. **Senha do Postgres** — trocar `posthog` por segredo forte (propagar em todas as connection strings).

**Gate de aceite (ADR-015):** após subir, gravar 1 sessão de **Session Replay** e relê-la, confirmando os objetos no bucket **B2** (valida o multipart do replay v2 contra o B2).
