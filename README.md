# Railway Templates — HASHING3

Monorepo de **templates Railway** reutilizáveis mantidos pela **HASHING3 Technologies**.
Cada subpasta é um template publicável no marketplace da Railway (deploy 1-clique) sob o
**Open Source Partner Program**.

## Princípios

- **Imagens reprodutíveis:** todo serviço usa imagem com **tag imutável** pinada a uma release
  estável, hospedada em registry próprio HASHING3 (`ghcr.io/hashing3-technologies/...`). Sem
  `:latest`, sem `:master`, sem SHA solto.
- **Documentação obrigatória:** cada template traz `README.md` (overview), `.env.example`
  (variáveis com exemplo) e `docs/` (setup, operação, custo, contingência).
- **Sem segredos versionados:** `.env.example` carrega apenas placeholders.

## Templates

| Template | Status | Descrição |
|---|---|---|
| [`posthog/`](posthog/) | 🚧 Em construção (Fase A) | PostHog self-hosted (analytics de produto) — stack moderno completo, object storage em Backblaze B2 |

## Licença

A definir pelo tech lead (MIT recomendado para o Open Source Partner Program da Railway).
