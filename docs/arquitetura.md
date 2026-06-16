# Arquitetura do template

Decisões de arquitetura do template PostHog self-hosted da HASHING3 — os serviços,
o pinning de imagens e o object storage. Fonte primária: os 21 Dockerfiles do
PostHog + o pipeline de build deste repo.

## Como o build funciona

O pipeline **builda** as imagens (não re-tagueia prontas): clona o source do
PostHog num `POSTHOG_APP_TAG`, gera GeoIP + scripts `compose/`, e faz
`docker build` de cada Dockerfile. Dois tipos de `FROM`:

- **Imagem Django principal** `ghcr.io/posthog/posthog:<tag>` — usada por
  `web`, `worker`, `plugins`, `temporal-django-worker`.
- **Componentes Rust/Go pré-buildados** `ghcr.io/posthog/posthog/<comp>:master` —
  `capture`, `replay-capture`, `cymbal`, `feature-flags`, `livestream`,
  `property-defs-rs`, `cyclotron-janitor` (puxados prontos do upstream).
- **Infra de terceiros** — clickhouse, postgres, redpanda, cp-kafka, caddy,
  redis, temporal, zookeeper.

## Os 19 serviços

| Serviço | Imagem upstream | Pinning HASHING3 |
|---|---|---|
| web | `posthog/posthog:${TAG}` | `@sha256` (commit-âncora) |
| worker | `posthog/posthog:${TAG}` | `@sha256` |
| plugins | `posthog/posthog:${TAG}` | `@sha256` |
| temporal-django-worker | `posthog/posthog:${TAG}` | `@sha256` |
| capture | `.../capture:master` | `:master@sha256` |
| replay-capture | `.../capture:master` | `:master@sha256` (mesma imagem) |
| cyclotron-janitor | `.../cyclotron-janitor:master` | `:master@sha256` |
| cymbal | `.../cymbal:master` | `:master@sha256` |
| feature-flags | `.../feature-flags:master` | `:master@sha256` |
| livestream | `.../livestream:master` | `:master@sha256` |
| property-defs-rs | `.../property-defs-rs:master` | `:master@sha256` |
| clickhouse | `clickhouse-server:25.8.12.129` | `:tag@sha256` |
| db | `postgres:15.12-alpine` | `:tag@sha256` |
| kafka-init | `redpanda:v25.1.9` | `:tag@sha256` |
| kafka | `cp-kafka:7.7.7` | `:tag@sha256` |
| proxy | `caddy:2-alpine` | `@sha256` |
| redis7 | `redis:7.2-alpine` | `:tag@sha256` |
| temporal | `auto-setup:1.20.0` | `:tag@sha256` |
| zookeeper | `zookeeper:3.7.0` | `:tag@sha256` |

**Object storage não roda como serviço** — vai 100% pro Backblaze B2 (ver
ADR-015), então o template tem **19 serviços** (sem MinIO/SeaweedFS locais).

## Decisões de arquitetura

### D1 — Digest pinning (reprodutibilidade)
Todo `FROM` é cravado por `@sha256` (ver `images.lock`) — nunca tag mutável.
Motivo: as imagens dos componentes Rust/Go saem como `:master` (rolling, muda sem
aviso) e o Caddy como `:latest`; sem pin, o build não é reprodutível. A saída é
publicada com tag = commit-âncora (não `:latest`) e **consumida por digest** no
template Railway (o pipeline emite o digest publicado no job summary).

### D2 — Skew de versão upstream (limitação conhecida)
O `web` é pinável por commit SHA, mas o upstream **não publica** as sub-imagens
Rust/Go por SHA — só `:master` (verificado: `capture:<sha>` → 404; `capture:master`
→ digest válido). Logo os componentes podem estar num commit diferente do `web`.
Mitigação: cada `:master` é cravado pelo digest do snapshot — reprodutível, mas o
skew é inerente ao upstream. Ao atualizar a âncora, re-resolver TODOS juntos
(`tools/resolve-digests.sh`).

### D3 — Registry próprio
Imagens publicadas em `ghcr.io/hashing3-technologies/posthog-railway` — auditável,
sob a org, com supply chain própria (Trivy + provenance).

### D4 — Object storage 100% Backblaze B2 (ADR-015)
Sem storage local efêmero (disco de bloco é caro/limitado e não é object storage
de volume). `OBJECT_STORAGE_*` + `SESSION_RECORDING_V2_S3_*` (Session Replay) +
`cymbal` apontam para o B2 (S3-compatible).

## Riscos aceitos

- **S3-compat do B2:** core S3 (PUT/GET/multipart) ok; sem presigned POST,
  object tagging, ACL por objeto. Uso server-side não bloqueia. **Gate:** smoke
  test do Session Replay → B2 (gravar + reler) antes de aceitar.
- **Egress de leitura de replay não é $0:** o `$0` da Bandwidth Alliance é
  B2↔Cloudflare; Railway↔B2 é direto e pago. Monitorar.
- **Fallback:** se o multipart do replay v2 falhar no B2, introduzir SeaweedFS
  só para `SESSION_RECORDING_V2_S3_*` (híbrido).
