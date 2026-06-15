# PostHog self-hosted — Railway Template (HASHING3)

Template Railway para subir **PostHog self-hosted** (analytics de produto open-source) com
deploy 1-clique. Object storage **100% no Backblaze B2** (sem storage local).

> **Status: ✅ Imagens prontas (Fase A).** Dockerfiles com digest pinning, workflow de
> build próprio (registry HASHING3), `images.lock`, `.env.example` e `docs/` implementados.
> Pendente: composição + publicação do template na Railway e smoke test do Session
> Replay → B2 (Fase 3), depois deploy no cliente MMO (Fase B).

## Estrutura desta pasta

| Caminho | O que é |
|---|---|
| [`dockerfiles/`](dockerfiles/) | 19 Dockerfiles, cada `FROM` cravado por `@sha256` |
| [`images.lock`](images.lock) | Fonte de verdade do digest pinning (imagem → digest + origem) |
| [`.env.example`](.env.example) | Referência de env vars (storage B2 verificado + wiring) |
| [`tools/resolve-digests.sh`](tools/resolve-digests.sh) | Re-resolve digests da fonte primária / audita drift do lock |
| [`docs/inventario-base.md`](docs/inventario-base.md) | Auditoria do template-base + as 4 falhas corrigidas |
| `../.github/workflows/posthog-build-images.yaml` | Build & publish das 19 imagens no GHCR |

**Reprodutibilidade (ADR-014):** todo `FROM` é por digest `sha256` (nunca tag
mutável). Para atualizar a âncora, rode `tools/resolve-digests.sh` (re-resolve da
fonte; nunca cravar digest de memória) e atualize `images.lock` + o workflow em
conjunto.

## Arquitetura (~19 serviços — variante do template-base, PostHog moderno)

O PostHog atual **não** é o "hobby" de 5 serviços. Esta variante (base: Hexatare/Railway) traz:

- **App:** `web`, `worker`, `plugins`, `temporal-django-worker`
- **Captura/processamento (Rust/Go):** `capture`, `replay-capture`, `feature-flags`,
  `property-defs-rs`, `cyclotron-janitor`, `cymbal` (error tracking), `livestream`
- **Dados:** `db` (Postgres), `clickhouse` (OLAP), `redis`
- **Streaming:** `kafka`, `zookeeper`, `kafka-init`
- **Orquestração:** `temporal`
- **Proxy:** Caddy
- **Object storage:** **externo (Backblaze B2)** — SeaweedFS e MinIO do template-base **removidos**

> **Footprint:** ClickHouse + Kafka + Zookeeper + Temporal são *always-on* (não escalam a
> zero). Baseline oficial de self-host: ~4 vCPU / 16 GB RAM / 30 GB. Planeje RAM permanente.

## Object storage — 100% Backblaze B2

Todas as camadas de object storage do PostHog apontam para o Backblaze B2 (S3-compatible),
no lugar do SeaweedFS/MinIO embarcados:

| Camada | Variáveis | Conteúdo |
|---|---|---|
| Object storage geral | `OBJECT_STORAGE_*` | exports, query cache, uploads |
| Session Replay (**ativo**) | `SESSION_RECORDING_V2_S3_*` | gravações de sessão (revisão de UX) |
| Error tracking | `OBJECT_STORAGE_ENDPOINT` do `cymbal` | artefatos de error tracking |

```
OBJECT_STORAGE_ENABLED=true
OBJECT_STORAGE_ENDPOINT=https://s3.<region>.backblazeb2.com
OBJECT_STORAGE_REGION=<region>
OBJECT_STORAGE_ACCESS_KEY_ID=<b2_application_key_id>
OBJECT_STORAGE_SECRET_ACCESS_KEY=<b2_application_key>
OBJECT_STORAGE_BUCKET=<your-bucket>

SESSION_RECORDING_V2_S3_ENDPOINT=https://s3.<region>.backblazeb2.com
SESSION_RECORDING_V2_S3_REGION=<region>
SESSION_RECORDING_V2_S3_ACCESS_KEY_ID=<b2_application_key_id>
SESSION_RECORDING_V2_S3_SECRET_ACCESS_KEY=<b2_application_key>
SESSION_RECORDING_V2_S3_BUCKET=<your-bucket>
```

> **Notas de compatibilidade.** O Backblaze B2 implementa o core S3 (PUT/GET/multipart via
> PUT), mas **não** suporta presigned POST, object tagging nem ACL por objeto. O uso é
> server-side, então isso normalmente não bloqueia — mas:
>
> - **Smoke test obrigatório (gate):** gravar uma sessão de Session Replay e **relê-la**,
>   confirmando os objetos no bucket B2 (valida o multipart contínuo do replay v2).
> - **Egress de leitura de replay não é grátis:** o `$0 egress` da Bandwidth Alliance é
>   B2↔Cloudflare; o tráfego PostHog(Railway)↔B2 é direto e pago. Monitorar.
> - **Fallback:** se o replay→B2 falhar no multipart, re-introduzir SeaweedFS apenas para
>   `SESSION_RECORDING_V2_S3_*` (híbrido).

## Roadmap de construção

- [x] Scaffold do repositório
- [x] Dockerfiles com digest pinning (`@sha256` resolvido da fonte primária) → registry HASHING3
- [x] Workflow de imagens próprio (publica por commit-âncora + emite digest)
- [x] `images.lock` + `resolve-digests.sh` (auditoria de drift)
- [x] `.env.example` (storage B2 verificado) + `docs/inventario-base.md` (falhas do base)
- [ ] Composição e publicação do template na Railway + smoke test do Session Replay → B2 (Fase 3)
- [ ] Deploy no cliente MMO (Fase B)
