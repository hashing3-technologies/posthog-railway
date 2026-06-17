# Railway composition runbook

> **Template:** HASHING3 self-hosted PostHog
> **Images:** `ghcr.io/hashing3-technologies/posthog-railway/<service>:9373a2b55081d3e711ad58bca060a6a9ab5d41a5`
> **Source of truth:** PostHog's `docker-compose.hobby.yml` + `docker-compose.base.yml` at commit `9373a2b55081d3e711ad58bca060a6a9ab5d41a5` (base anchors resolved against the hobby file).
> **Object storage:** 100% Backblaze B2 (S3-compatible). The official compose's `objectstorage` (MinIO) and `seaweedfs` services are **not included**; every endpoint that pointed at `objectstorage:19000` or `seaweedfs:8333` was switched to B2.

Quick legend:
- **GHCR** = GitHub Container Registry. Here under the `hashing3-technologies` org.
- **B2** = Backblaze B2 (S3-compatible object storage).
- **`[confirm]`** = item that depended on a repo file; the final section consolidates which were resolved (baked into the images) and which are deploy decisions.

---

## How to add a service on Railway

1. In the Railway project: **New Service → Deploy from Docker Image**.
2. Image: `ghcr.io/hashing3-technologies/posthog-railway/<service>:9373a2b55081d3e711ad58bca060a6a9ab5d41a5` (Railway **pulls** the ready-made image; it does not build a Dockerfile).
3. Name the service **exactly** with its canonical name (e.g. `clickhouse`, `db`, `kafka`, `redis7`, `zookeeper`, `temporal`). That name is the internal hostname used by the env vars (e.g. `postgres://posthog:posthog@db:5432/posthog`).
4. Paste the env vars from the service's subsection.
5. For stateful services, attach a **Volume** at the indicated mount path.

> **Prerequisite:** the 19 GHCR packages must be **public** (otherwise Railway can't pull without a registry credential).

> **Tip — wiring & the canvas:** prefer Railway reference variables
> (`${{Kafka.RAILWAY_PRIVATE_DOMAIN}}`, `${{Postgres.RAILWAY_PRIVATE_DOMAIN}}`, …)
> instead of hardcoded hostnames where you can. They resolve to the service's
> private domain, draw the connection arrow on the canvas, and re-map
> automatically if you rename the service. Hardcoded short hostnames (`kafka`,
> `db`, …) also resolve on Railway's private network, so both work.

### General boot order

Railway has no real `depends_on`; respect the order when creating/starting. Most services have `restart: on-failure`, so they reconnect once the dependency shows up:

```
1. Base infra:    db, clickhouse, redis7, zookeeper
2. Messaging:     kafka            (depends on zookeeper)
3. Bootstrap:     kafka-init       (creates topics; depends on a healthy kafka)
4. Orchestration: temporal         (depends on db)
5. Django app:    web → worker → plugins → temporal-django-worker
6. Rust/services: capture, replay-capture, property-defs-rs, cyclotron-janitor,
                  cymbal, feature-flags, livestream
7. Edge:          proxy            (template default; routes to web + capture +
                  feature-flags + livestream — bring it up last, once they exist)
```

---

## db (Postgres)

- **Image:** `.../db:9373a2b...` *(upstream `postgres:15.12-alpine`)*
- **Env:**
```env
POSTGRES_USER=posthog
POSTGRES_DB=posthog
POSTGRES_PASSWORD=posthog
```
- **Volume:** `postgres-data` → `/var/lib/postgresql/data`
- **Ports:** `5432`
- **depends_on:** none (base infra). Healthcheck: `pg_isready -U posthog`.

## redis7

- **Image:** `.../redis7:9373a2b...` *(upstream `redis:7.2-alpine`)*
- **Command (already in the image):** `redis-server --maxmemory-policy allkeys-lru --maxmemory 200mb`
- **Env:** none.
- **Volume:** `redis7-data` → `/data`
- **Ports:** `6379`
- **depends_on:** none.

## clickhouse

- **Image:** `.../clickhouse:9373a2b...` *(upstream `clickhouse/clickhouse-server:25.8.12.129`)*
- **Env:**
```env
CLICKHOUSE_SKIP_USER_SETUP=1
KAFKA_HOSTS=kafka:9092
```
- **Volume:** `clickhouse-data` → `/var/lib/clickhouse`. The configs/IDL/scripts (config.xml, users.xml, default.xml, user_defined_function.xml, IDL, initdb, user_scripts) are **already baked into the image** (COPY at build time) — no need to mount from the repo.
- **Ports:** `9000` (native), `8123` (HTTP)
- **depends_on:** `kafka`, `zookeeper`

## zookeeper

- **Image:** `.../zookeeper:9373a2b...` *(upstream `zookeeper:3.7.0`)*
- **Env:** none.
- **Volumes:** `zookeeper-data`→`/data`, `zookeeper-datalog`→`/datalog`, `zookeeper-logs`→`/logs`
- **Ports:** `2181` (client)
- **depends_on:** none.

## kafka

> Real image: **confluentinc/cp-kafka** (Kafka broker). Hostname `kafka`.
> PostHog's official compose uses Redpanda; this template ships cp-kafka instead
> (single-node + zookeeper). `kafka-init` uses `rpk`, which speaks to any
> Kafka-protocol broker, so it works against cp-kafka too.

- **Image:** `.../kafka:9373a2b...` *(upstream `confluentinc/cp-kafka:7.7.7`)*
- **Env:**
```env
KAFKA_BROKER_ID=1
KAFKA_ZOOKEEPER_CONNECT=zookeeper:2181
KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092
KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka:9092
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=PLAINTEXT:PLAINTEXT
KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT
KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1
KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1
KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1
KAFKA_AUTO_CREATE_TOPICS_ENABLE=true
KAFKA_LOG_RETENTION_HOURS=1
```
- **Volume:** `kafka-data` → **`/var/lib/kafka/data`** (cp-kafka's data dir). The image runs as **`root`** (see `kafka.Dockerfile`) so it can write to the Railway volume, which is mounted `root:root` — a non-root broker fails the writable preflight and crash-loops.
- **Ports:** `9092` (Kafka).
- **depends_on:** `zookeeper`

## kafka-init

> Ephemeral one-shot job: creates the `exceptions_ingestion` and `clickhouse_events_json` topics, then exits. On Railway, run it as a service that exits when done (or a manual job; it may show as "crashed" on exit — that's expected).

- **Image:** `.../kafka-init:9373a2b...` *(upstream Redpanda; own entrypoint)*
- **Command (already in the image):** waits for `kafka:9092` and creates the 2 topics (`-p 1 -r 1`).
- **Env / Volume / Ports:** none.
- **depends_on:** `kafka` (healthy)

## temporal

- **Image:** `.../temporal:9373a2b...` *(upstream `temporalio/auto-setup:1.20.0`)*
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
> `ENABLE_ES=false` (hobby override) turns off Elasticsearch — consistent with **not** including `elasticsearch`/`temporal-ui`/`temporal-admin-tools`.
- **Volume:** none. The `development-sql.yaml` (dynamicconfig) is **already baked into the image** (COPY at build time).
- **Ports:** `7233` (gRPC)
- **depends_on:** `db` (healthy)

## web

> Main Django/PostHog. Inherits the `*worker_env` anchor from base; the hobby file adds the block below.

- **Image:** `.../web:9373a2b...`
- **Command (already in the image):** `/compose/start` (baked in).
- **Env:**
```env
# inherited from the *worker_env anchor (base)
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
# hobby block (web)
SITE_URL=https://<DOMAIN>
LIVESTREAM_HOST=https://<DOMAIN>/livestream
SECRET_KEY=<POSTHOG_SECRET>
ENCRYPTION_SALT_KEYS=<ENCRYPTION_SALT_KEYS>
USE_GRANIAN=true
# 1, not 2: GRANIAN_WORKERS=2 (the compose default) did not boot reliably on
# Railway in our runs (the service flapped on startup); =1 boots cleanly.
# Prefer scaling out with replicas over in-process workers here.
GRANIAN_WORKERS=1
OPT_OUT_CAPTURE=false
# storage → Backblaze B2 (see final section)
OBJECT_STORAGE_ENABLED=true
OBJECT_STORAGE_ENDPOINT=https://s3.<region>.backblazeb2.com
OBJECT_STORAGE_ACCESS_KEY_ID=<b2_application_key_id>
OBJECT_STORAGE_SECRET_ACCESS_KEY=<b2_application_key>
SESSION_RECORDING_V2_S3_ENDPOINT=https://s3.<region>.backblazeb2.com
SESSION_RECORDING_V2_S3_ACCESS_KEY_ID=<b2_application_key_id>
SESSION_RECORDING_V2_S3_SECRET_ACCESS_KEY=<b2_application_key>
```
- **Volume:** none.
- **Ports:** `8000`
- **depends_on:** `db`, `redis7`, `clickhouse`, `kafka`

> **First boot is long (~2 min) — a 502 in that window is normal.** `web` runs
> Django + ClickHouse migrations at startup before it serves; expect 502 / health
> failures until they finish. Changing pids in the logs are the start-script
> stages, **not** a crash-loop. Wait for `/preflight` → `200` before assuming
> something is wrong. (After the first boot, restarts are fast — migrations are
> already applied.)

## worker

> Celery worker + scheduler. Inherits `*worker_env`.

- **Image:** `.../worker:9373a2b...`
- **Command (already in the image):** `./bin/docker-worker-celery --with-scheduler`
- **Env:** the entire `*worker_env` anchor (identical to `web`) plus:
```env
SITE_URL=https://<DOMAIN>
SECRET_KEY=<POSTHOG_SECRET>
ENCRYPTION_SALT_KEYS=<ENCRYPTION_SALT_KEYS>
OBJECT_STORAGE_ENABLED=true
POSTHOG_SKIP_MIGRATION_CHECKS=1
# storage → B2 (OBJECT_STORAGE_* + SESSION_RECORDING_V2_S3_*, same as web)
```
- **Volume:** none. **Ports:** none.
- **depends_on:** `db`, `redis7`, `clickhouse`, `kafka`, `web`

## plugins

> Ingestion / CDP. Webhooks on port `6738`.

- **Image:** `.../plugins:9373a2b...`
- **Command (already in the image):** `./bin/posthog-node --no-restart-loop`
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
# storage → B2 (OBJECT_STORAGE_* + SESSION_RECORDING_V2_S3_*, same as web)
```
> `KAFKA_HOSTS=kafka:9092` here (with port), unlike the Django anchor (`kafka`).
- **Volume:** none. **Ports:** `6738` (webhooks).
- **depends_on:** `db`, `redis7`, `clickhouse`, `kafka`

## temporal-django-worker

- **Image:** `.../temporal-django-worker:9373a2b...`
- **Command (already in the image):** `/compose/temporal-django-worker`
- **Env:** the `*worker_env` anchor (same as web) plus:
```env
TEMPORAL_HOST=temporal
SITE_URL=https://<DOMAIN>
SECRET_KEY=<POSTHOG_SECRET>
```
- **Volume:** none. **Ports:** none.
- **depends_on:** `db`, `redis7`, `clickhouse`, `kafka`, `temporal`

## capture

- **Image:** `.../capture:9373a2b...`
- **Env:**
```env
ADDRESS=0.0.0.0:3000
KAFKA_TOPIC=events_plugin_ingestion
KAFKA_HOSTS=kafka:9092
REDIS_URL=redis://redis7:6379/
CAPTURE_MODE=events
RUST_LOG=info,rdkafka=warn
```
- **Volume:** none. **Ports:** `3000`.
- **depends_on (logical):** `kafka`, `redis7`

## replay-capture

> Same image as `capture`, `recordings` mode.

- **Image:** `.../replay-capture:9373a2b...`
- **Env:**
```env
ADDRESS=0.0.0.0:3000
KAFKA_TOPIC=session_recording_snapshot_item_events
KAFKA_HOSTS=kafka:9092
REDIS_URL=redis://redis7:6379/
CAPTURE_MODE=recordings
```
- **Volume:** none. **Ports:** `3000`.
- **depends_on (logical):** `kafka`, `redis7`

## cyclotron-janitor

- **Image:** `.../cyclotron-janitor:9373a2b...`
- **Env (effective hobby-over-base merge):**
```env
DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
KAFKA_HOSTS=kafka:9092
KAFKA_TOPIC=clickhouse_app_metrics2
```
> The hobby file points `DATABASE_URL` at the `posthog` database (not a separate `cyclotron` database).
- **Volume:** none. **Ports:** none.
- **depends_on:** `db`, `kafka`

## cymbal

> Error tracking (Rust). Uses B2 storage.

- **Image:** `.../cymbal:9373a2b...`
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
# storage → B2 (was http://seaweedfs:8333)
OBJECT_STORAGE_BUCKET=<bucket>
OBJECT_STORAGE_ENDPOINT=https://s3.<region>.backblazeb2.com
OBJECT_STORAGE_ACCESS_KEY_ID=<b2_application_key_id>
OBJECT_STORAGE_SECRET_ACCESS_KEY=<b2_application_key>
OBJECT_STORAGE_FORCE_PATH_STYLE=true
```
- **Volume:** none. The `GeoLite2-City.mmdb` at `/share` is **already baked into the image** (COPY at build time).
- **Ports:** `3302`.
- **depends_on:** `kafka-init` (done), `db`, `redis7`

## feature-flags

- **Image:** `.../feature-flags:9373a2b...`
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
- **Volume:** none. GeoLite2 at `/share` **baked into the image**.
- **Ports:** `3001`.
- **depends_on:** `db`, `redis7`

## livestream

> Go, real-time events. Port `8080`.

- **Image:** `.../livestream:9373a2b...`
- **Env:**
```env
LIVESTREAM_JWT_SECRET=<POSTHOG_SECRET>
```
> = the same `$POSTHOG_SECRET` as `SECRET_KEY`.
- **Volume:** none. The `configs.yml` at `/configs/configs.yml` is **already baked into the image** (COPY at build time).
- **Ports:** `8080`.
- **depends_on:** `kafka`

## property-defs-rs

- **Image:** `.../property-defs-rs:9373a2b...`
- **Env:**
```env
DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
KAFKA_HOSTS=kafka:9092
SKIP_WRITES=false
SKIP_READS=false
FILTER_MODE=opt-out
```
- **Volume:** none. **Ports:** none declared.
- **depends_on:** `kafka-init` (done), `db`

## proxy (Caddy) — included (template default)

> Single-domain, path-based reverse proxy = the one public entry point for
> PostHog. See [`architecture.md` → D5 (Edge routing)](architecture.md#d5--edge-routing-how-posthog-is-exposed)
> for the why and the two alternatives (Railway native domains, external proxy).
> The routing config is the versioned [`Caddyfile`](../Caddyfile) at the repo
> root; its upstreams (`web:8000`, `capture:3000`, `capture-ai:3000`,
> `replay-capture:3000`, `feature-flags:3001`, `plugins:6738`, `livestream:8080`)
> match the services in this runbook.

- **Image:** `.../proxy:9373a2b...` *(upstream `caddy:2-alpine`)*
- **Env:**
```env
# Paste the full contents of /Caddyfile (repo root) into this one var.
# The image bakes no Caddyfile: proxy.Dockerfile writes ${CADDYFILE} to disk
# and runs Caddy. No TLS block / CADDY_HOST needed — Railway terminates TLS at
# the edge and the Caddyfile listens on :8080 with auto_https off.
CADDYFILE=<contents of /Caddyfile>
```
- **Volumes:** none — TLS is terminated at the Railway edge, so Caddy stores no
  certs (no `/data` / `/config` persistence needed in this mode).
- **Ports:** `8080` (generate the Railway domain pointing at port **8080**).
- **depends_on:** `web`, `capture`, `feature-flags`, `livestream` (and
  `capture-ai` / `replay-capture` / `plugins` once those are up).

**Exposing it (two modes, same Caddyfile — see D5.1):**

1. **Native domain (default):** generate the proxy's Railway domain on port 8080
   → PostHog is live at `https://<proxy>.up.railway.app`. Set `SITE_URL` and
   `LIVESTREAM_HOST` (on `web`) to that URL.
2. **Custom domain (1-step upgrade):** add your domain to this same `proxy`
   service (Railway issues the cert) and update `SITE_URL` / `LIVESTREAM_HOST`.
   No Caddyfile edit — `:8080` already accepts any Host.

> **Tip:** to draw the proxy→upstream arrows on the canvas, optionally replace
> each hostname in the Caddyfile with a reference var, e.g.
> `${{Web.RAILWAY_PRIVATE_DOMAIN}}:8000`. Same routing, just visible wiring.

---

## Shared variables / B2 storage

### Postgres
```env
DATABASE_URL=postgres://posthog:posthog@db:5432/posthog   # almost every service
POSTGRES_USER=posthog
POSTGRES_DB=posthog
POSTGRES_PASSWORD=posthog
PGHOST=db
PGUSER=posthog
PGPASSWORD=posthog
```
> In production, replace the `posthog` password with a strong secret and propagate it across **all** connection strings at once.

### ClickHouse (`*worker_env` anchor)
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

### Kafka — TWO formats (do not unify)
```env
KAFKA_HOSTS=kafka         # Django services via anchor (web, worker, temporal-django-worker)
KAFKA_HOSTS=kafka:9092    # Rust + plugins + clickhouse (capture, replay-capture, property-defs-rs, cyclotron-janitor, cymbal)
```

### Redis
```env
REDIS_URL=redis://redis7:6379/
COOKIELESS_REDIS_HOST=redis7   # plugins, feature-flags
COOKIELESS_REDIS_PORT=6379
```

### Application secrets
```env
SECRET_KEY=<POSTHOG_SECRET>                    # web, worker, plugins, temporal-django-worker
ENCRYPTION_SALT_KEYS=<ENCRYPTION_SALT_KEYS>    # web, worker, plugins
LIVESTREAM_JWT_SECRET=<POSTHOG_SECRET>         # livestream (= same POSTHOG_SECRET)
SITE_URL=https://<DOMAIN>                      # web, worker, plugins, temporal-django-worker
```
> Generate `POSTHOG_SECRET` (`openssl rand -hex 32`) and `ENCRYPTION_SALT_KEYS` (`openssl rand -hex 16`).

### Storage → Backblaze B2 (replaces MinIO/SeaweedFS)

Apply on the services that use storage: **web**, **worker**, **plugins** (`OBJECT_STORAGE_*` + `SESSION_RECORDING_V2_S3_*`) and **cymbal** (`OBJECT_STORAGE_*` with bucket + path-style). They all point at the **same** B2.

```env
OBJECT_STORAGE_ENABLED=true
OBJECT_STORAGE_ENDPOINT=https://s3.<region>.backblazeb2.com
OBJECT_STORAGE_REGION=<region>                 # e.g. us-west-004
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

Replacement map (original compose → B2):

| Variable | Was | Becomes (B2) |
|---|---|---|
| `OBJECT_STORAGE_ENDPOINT` | `http://objectstorage:19000` | `https://s3.<region>.backblazeb2.com` |
| `OBJECT_STORAGE_ACCESS_KEY_ID` | `object_storage_root_user` | `<b2_application_key_id>` |
| `OBJECT_STORAGE_SECRET_ACCESS_KEY` | `object_storage_root_password` | `<b2_application_key>` |
| `SESSION_RECORDING_V2_S3_ENDPOINT` | `http://seaweedfs:8333` | `https://s3.<region>.backblazeb2.com` |
| `SESSION_RECORDING_V2_S3_*` keys | `any` / `any` | `<b2_application_key_id>` / `<b2_application_key>` |
| `OBJECT_STORAGE_ENDPOINT` (cymbal) | `http://seaweedfs:8333` | `https://s3.<region>.backblazeb2.com` |

---

## Resolution of the `[confirm]` items

**Resolved** (verified in this repo's Dockerfiles — the files are **baked into the images** via `COPY` at build time, no bind mount/volume needed on Railway):

- **clickhouse** — config.xml, users.xml, default.xml, user_defined_function.xml, IDL, initdb, user_scripts → baked in.
- **temporal** — `development-sql.yaml` (dynamicconfig) → baked in.
- **web / temporal-django-worker** — the `/compose/start` and `/compose/temporal-django-worker` scripts → baked in.
- **cymbal / feature-flags** — `GeoLite2-City.mmdb` at `/share` → baked in.
- **livestream** — `configs.yml` → baked in.
- **kafka volume** — `/var/lib/kafka/data` (cp-kafka's data dir; the hobby's `/bitnami/kafka` is a `bitnami/kafka` leftover and does not apply). The `kafka` image runs as `root` (`kafka.Dockerfile`) so it can write to the Railway volume (mounted `root:root`).

**Deploy decisions (your call):**

1. **B2 bucket/region** — `web/worker/plugins` don't receive an explicit bucket/region in the compose (only `cymbal` does). Set `OBJECT_STORAGE_BUCKET` + `OBJECT_STORAGE_REGION` at deploy time; use the same bucket for all.
2. **proxy / routing** — **decided: the template keeps the built-in Caddy proxy as
   the default** (single-domain path-based routing on the native Railway domain;
   custom domain is a 1-step upgrade). See [`architecture.md` → D5 (Edge routing)](architecture.md#d5--edge-routing-how-posthog-is-exposed)
   and D5.1 for the two proxy modes and the alternatives (native domains or an
   external proxy like Cloudflare) if you choose to drop Caddy.
3. **Postgres password** — replace `posthog` with a strong secret (propagate across every connection string).

**Acceptance check:** after bringing it up, record one **Session Replay** and play it back, confirming the objects land in the **B2** bucket (validates replay v2 multipart against B2).
