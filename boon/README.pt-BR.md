[English](./README.md) · **Português**

# Boon

> *Um boon é uma dívida ou favor formal negociado entre os Kindred — a moeda de prestígio e obrigação em Vampire: The Masquerade. Apropriado para uma plataforma construída sobre transações de valor.*

[← Voltar ao Elysium](../README.pt-BR.md)

**Boon** é uma plataforma de venda de conteúdo digital (no espírito de Hotmart / Kiwify): produtores
publicam produtos digitais, compradores fazem o checkout por uma **oferta** específica, e o acesso é
entregue automaticamente assim que o pagamento é confirmado. Um gateway de borda Nginx fica à frente
de dois SPAs e duas APIs; o trabalho em background roda em workers Sidekiq segregados.

> ⚠️ Projeto de portfólio + aprendizado — não é um produto de pagamento real. Os pagamentos rodam em sandbox/mock; não use com dados reais de cartão.

## Por que este projeto

Ele espelha trabalho real de produção que fiz em plataformas de pagamento (seleção dinâmica de
gateway, detecção de fraude, jobs em background, performance de checkout) e demonstra a condução de
trabalho técnico através de **múltiplos serviços e codebases** — roteamento de borda, decisões de
arquitetura, testes e observabilidade.

## Arquitetura

Monorepo de serviços deployáveis de forma independente atrás de um gateway de borda Nginx,
compartilhando um único banco cujo schema pertence a uma gem `domain` dentro do `core`.

```
                         ┌───────────────────────────┐
   elysium.com  ────────▶│   nginx (gateway de borda)│
                         └──────────────┬────────────┘
     /            ┌──────────────┬──────┴──────┬──────────────────┐
     │            ▼              ▼             ▼                  ▼
  core-frontend   checkout-frontend    /api (Swagger)      /api/products/{id} → core (API)
  (Vue+Vuetify)   (/checkout, Vue)                         /api/checkout/{stub}, POST /api/checkout → checkout (API)

  core ──┐                                   ┌── worker (Sidekiq)
         ├─ compart. ▶ core/domain (gem) ◀───┤     fila `sales`         → pagamentos/estornos (+gateway)
  checkout┘          models + migrations     │     fila `notifications` → email/push/sms
         │                                    │
         └──────────▶ Redis (filas) ◀─────────┘      todos os serviços ─▶ PostgreSQL (compartilhado)
```

- **core** — API Rails: cadastro de produtor, produtos, relatórios, orders, solicitações de reembolso/estorno. Usa a gem `domain`.
- **core/domain** — gem (engine Rails): models (ActiveRecord) + migrations. Fonte única da verdade do schema.
- **checkout** — API Rails mínima: `GET /api/checkout/{stub}` (produto sob uma oferta), `POST /api/checkout` (cria compra). Só registra + enfileira.
- **worker** — Sidekiq, um codebase, duas filas como processos/containers separados: `sales` (validação de pagamento, **seleção de gateway**, cobrança, estado do pedido, estornos; dono da abstração de gateway; Sequel para acesso a dados) e `notifications` (email/push/sms). *(Reescrita em Go planejada — veja ADR-0002.)*
- **core-frontend / checkout-frontend** — SPAs em Vue 3 + Vuetify.
- **nginx** — gateway de borda, roteamento por path (abaixo).

## Roteamento (como em produção)

```
elysium.com                    → core-frontend
elysium.com/checkout           → checkout-frontend
elysium.com/api                → Swagger UI (core + checkout)
elysium.com/api/products/{id}  → API do core (busca produto)
elysium.com/api/checkout/{stub}→ API do checkout (produto sob uma oferta)
POST elysium.com/api/checkout  → API do checkout (cria compra)
```

## Funcionalidades (v1)

- Cadastro de produtor com validação de **CPF/CNPJ** por dígito verificador (mod 11, local — sem consulta à Receita Federal).
- Produtos + **ofertas**; **upload de PDF** (Active Storage); acesso via **link de e-mail assinado e com expiração**.
- **Checkout** mínimo e desacoplado.
- **Workers assíncronos segregados** (`sales` / `notifications`) com retry independente + isolamento de falha.
- **Dashboard do produtor**: vendas por produto, receita, comissão, produto mais vendido.

## Stack

Ruby on Rails (API-only) · Vue 3 + Vuetify · Sidekiq + Redis · PostgreSQL · Sequel (worker) · Nginx · RSpec · Docker Compose

## Como começar

```bash
docker compose up
```

(Wiring — banco, Sidekiq/Redis, migrations do domain, base do Vite para /checkout, nginx.conf — documentado no PROJECT.md.)

## Documentação

- [Architecture Decision Records](./docs/adr/) — Sidekiq vs Solid Queue, worker→Go, abstração de gateway, banco compartilhado, segregação de workers, SPA vs SSR, gateway de borda, contrato de fila.

## Roadmap (fora do escopo da v1)

Afiliados & repasses · streaming de vídeo · fraude com ML · multi-tenancy · impostos. Swagger e o
worker em Go são incrementos, não bloqueadores do MVP.

---

[← Voltar ao Elysium](../README.pt-BR.md)
