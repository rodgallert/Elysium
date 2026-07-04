# Architecture Decision Records

Short records of the significant decisions behind Boon. Each captures context, the decision, and its
consequences. They are a first-class part of this project — they show *why*, not just *what*.

| ADR | Decision |
|-----|----------|
| ADR-0001 | Sidekiq + Redis over Rails 8's default Solid Queue |
| ADR-0002 | Worker (sales engine) to be rewritten in Go later; kept portable (Sequel, isolated provider) |
| ADR-0003 | Payment-gateway abstraction lives in the worker; mock first, Stripe later |
| ADR-0004 | Shared `domain` gem + shared database (trade-off accepted for scope) |
| ADR-0005 | Worker segregation by queue (`sales` vs `notifications`) for fault isolation + independent scaling |
| ADR-0006 | Front end is Vue 3 + Vuetify SPA, not Nuxt/SSR |
| ADR-0007 | Nginx edge gateway with path-based routing (this folder has the full record) |
| ADR-0008 | Queue contract by payload, not shared job classes — preserves Go portability |

> Only ADR-0007 is written out as a full example. The rest are summarized in `PROJECT.md`; write each
> full record here as the decision gets implemented. Suggested filename pattern: `0001-title.md`.
