# Inventário do template-base + falhas corrigidas

Auditoria do template-base [`Hexatare/posthog-railway-template`](https://github.com/Hexatare/posthog-railway-template)
(snapshot inspecionado em 2026-06-15), base da variante HASHING3. Fonte primária:
os 21 Dockerfiles + `.github/workflows/build-images.yaml` do base, lidos
diretamente (não memória/catálogo).

## Como o base funciona

O workflow **builda** imagens próprias (não re-tagueia prontas): clona o source
do PostHog num `POSTHOG_APP_TAG`, gera GeoIP + scripts `compose/`, e faz
`docker build` de cada Dockerfile. Dois tipos de `FROM`:

- **Imagem Django principal** `ghcr.io/posthog/posthog:<tag>` — usada por
  `web`, `worker`, `plugins`, `temporal-django-worker` (via `ARG POSTHOG_APP_TAG`).
- **Componentes Rust/Go pré-buildados** `ghcr.io/posthog/posthog/<comp>:master` —
  `capture`, `replay-capture`, `cymbal`, `feature-flags`, `livestream`,
  `property-defs-rs`, `cyclotron-janitor` (puxados prontos do upstream).
- **Infra de terceiros** — clickhouse, postgres, redpanda, cp-kafka, caddy,
  redis, temporal, zookeeper.

## Os 21 serviços → 19 na variante HASHING3

| Serviço | Imagem base (Hexatare) | Ação HASHING3 |
|---|---|---|
| web | `posthog/posthog:${TAG}` | pin `@sha256` (commit-âncora) |
| worker | `posthog/posthog:${TAG}` | pin `@sha256` |
| plugins | `posthog/posthog:${TAG}` | pin `@sha256` |
| temporal-django-worker | `posthog/posthog:${TAG}` | pin `@sha256` |
| capture | `.../capture:master` | pin `:master@sha256` |
| replay-capture | `.../capture:master` | pin `:master@sha256` (mesma imagem) |
| cyclotron-janitor | `.../cyclotron-janitor:master` | pin `:master@sha256` |
| cymbal | `.../cymbal:master` | pin `:master@sha256` |
| feature-flags | `.../feature-flags:master` | pin `:master@sha256` |
| livestream | `.../livestream:master` | pin `:master@sha256` |
| property-defs-rs | `.../property-defs-rs:master` | pin `:master@sha256` |
| clickhouse | `clickhouse-server:25.8.12.129` | pin `:tag@sha256` |
| db | `postgres:15.12-alpine` | pin `:tag@sha256` |
| kafka-init | `redpanda:v25.1.9` | pin `:tag@sha256` |
| kafka | `cp-kafka:7.7.7` | pin `:tag@sha256` |
| proxy | `caddy:latest` ⚠️ | **caddy:2-alpine** `@sha256` |
| redis7 | `redis:7.2-alpine` | pin `:tag@sha256` |
| temporal | `auto-setup:1.20.0` | pin `:tag@sha256` |
| zookeeper | `zookeeper:3.7.0` | pin `:tag@sha256` |
| **objectstorage** | `minio/minio` | **REMOVIDO** (B2) |
| **seaweedfs** | `chrislusf/seaweedfs:4.03` | **REMOVIDO** (B2) |

21 − 2 (storage embarcado) = **19 serviços**. Confere com ADR-014.

## Falhas do base — e como a variante corrige

### F1 — Reprodutibilidade quebrada (tags mutáveis)
O base referencia imagens por tag mutável em 3 frentes:
- componentes Rust/Go por `:master` (rolling — muda sem aviso);
- `proxy` por `caddy:latest`;
- publica as próprias imagens como `:latest` (o que o Railway consome).

**Correção (ADR-014):** todo `FROM` cravado por `@sha256` (ver `images.lock`);
saída publicada com tag = commit-âncora (não `:latest`) e **consumida por
digest** no template Railway (o workflow emite o digest publicado no job summary).

### F2 — Skew de versão entre `web` e componentes (limitação do upstream)
O `web` é pinável por commit SHA, mas o upstream **não publica** as sub-imagens
Rust/Go por SHA — só `:master` (verificado: `capture:<sha>` → 404; `capture:master`
→ digest válido). Logo os componentes podem estar num commit diferente do `web`.

**Correção parcial:** cada `:master` é cravado pelo digest do snapshot de
2026-06-15 — reprodutível, mas o skew é **inerente ao upstream** e não some.
Documentado no `images.lock`; ao atualizar a âncora, re-resolver TODOS juntos.

### F3 — Registry de terceiros
O base publica em `ghcr.io/hexatare/...`. **Correção:** registry próprio
`ghcr.io/hashing3-technologies/posthog-railway` (auditável, sob a org).

### F4 — Storage embarcado efêmero
SeaweedFS + MinIO rodam como serviços no projeto Railway, com dados em disco de
bloco (caro, limitado, não é object storage de volume).
**Correção (ADR-015):** removidos; `OBJECT_STORAGE_*` + `SESSION_RECORDING_V2_S3_*`
apontam para Backblaze B2.

## Riscos aceitos (decisão do tech lead)

- **S3-compat do B2:** core S3 (PUT/GET/multipart) ok; sem presigned POST,
  object tagging, ACL por objeto. Uso server-side não bloqueia. **Gate:** smoke
  test do Session Replay → B2 (gravar + reler) antes de aceitar.
- **Egress de leitura de replay não é $0:** o `$0` da Bandwidth Alliance é
  B2↔Cloudflare; Railway↔B2 é direto e pago. Monitorar.
- **Fallback:** se o multipart do replay v2 falhar no B2, re-introduzir SeaweedFS
  só para `SESSION_RECORDING_V2_S3_*` (híbrido).
