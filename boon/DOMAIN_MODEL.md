# Boon — domain model (working reference)

Snapshot of the entities defined so far for `core/domain`. This is documentation of decisions
already made by the author — **not a spec for Claude to implement** (see `CLAUDE.md`: models/
migrations are the author's territory). Tipos usam a nomenclatura de `MIGRATION_TYPES.md`.
Valores monetários em centavos (`integer`). `created_at`/`updated_at` sempre implícitos, não listados.

Enums são **string-backed** (ver convenção em `CLAUDE.md`).

---

## Producer

| Propriedade | Tipo | Notas |
|---|---|---|
| `name` | `string` | |
| `email` | `string` | único — considerar normalizar case (`downcase`) antes de indexar |
| `password_digest` | `string` | via `has_secure_password` (bcrypt) |
| `document` | `string` | CPF (11) ou CNPJ (14), só dígitos; único. **String, não integer** — zero à esquerda |
| `birth_date` | `date` | |
| `phone` | `string` | |
| `street`, `number`, `city`, `state`, `zip` | `string` | endereço em campos soltos |
| `status` | `string` (enum) | `pending`, `active`, `suspended`, `blocked`, `deleted`, `pending_deletion` (só permite deleção sem venda atrelada) |

Relações: `has_many :products`

---

## Product

| Propriedade | Tipo | Notas |
|---|---|---|
| `producer_id` | FK → `producers` | |
| `name` | `string` | |
| `description` | `text` | texto estável (o que o produto é) |
| `image` | Active Storage (`has_one_attached`) | não é coluna |
| conteúdo (PDF) | Active Storage (`has_one_attached`) | não é coluna — nome do attachment a definir |
| `status` | `string` (enum) | pelo menos `active`, `blocked`, `deleted` — ⚠️ conferir se `pending_deletion` também se aplica aqui ou é só de Producer |

Relações: `belongs_to :producer`; `has_many :offers`

---

## Offer

| Propriedade | Tipo | Notas |
|---|---|---|
| `product_id` | FK → `products` | |
| `name` | `string` | |
| `stub` | `string` | **não** `uuid` nativo — gerado via `SecureRandom.uuid` no Ruby, pra permitir valor customizado (slug legível) no futuro sem trocar tipo de coluna. Único |
| `description` | `text` | CTA que aparece no checkout |
| `price` | `integer` | centavos |
| `currency` | `string` | default `"BRL"`; sem multi-moeda planejada |
| `status` | `string` (enum) | resolve a dúvida status-vs-active a favor de enum; pelo menos `active`, `blocked`, `deleted` |

Relações: `belongs_to :product`; `has_many :orders`

---

## Customer

| Propriedade | Tipo | Notas |
|---|---|---|
| `email` | `string` | único |
| `password_digest` | `string` | senha gerada automaticamente, guardada como hash |
| `name` | `string` | |
| `document` | `string` | CPF só dígitos. ⚠️ **Aberto**: se o CPF puder variar por compra (presente pra terceiro, por ex.), esse campo deveria morar em `Order`, não aqui — decisão ainda não fechada |

Relações: `has_many :orders`

---

## Order

| Propriedade | Tipo | Notas |
|---|---|---|
| `offer_id` | FK → `offers` | |
| `customer_id` | FK → `customers` | |
| `amount_paid` | `integer` | centavos — **valor total pago, e só isso** (ADR-0009: o destrinchado vive em `Payment`) |
| `installments` | `integer` | número de parcelas |
| `payment_method` | `string` (enum) | `boleto`, `pix`, `credit` |
| `status` | `string` (enum) | status do **pedido em si**: `pending`, `processing`, `paid`, `refused`, `chargedback`, `refunded` |

Relações: `belongs_to :offer`, `belongs_to :customer`; `has_many :payments` (N tentativas por pedido)

Nota: email do comprador **não** duplica aqui — mora em `Customer`.

---

## Payment

| Propriedade | Tipo | Notas |
|---|---|---|
| `order_id` | FK → `orders` | |
| `gateway` | `string` | qual provedor processou esta tentativa |
| `gateway_id` | `string` | id externo da transação. Índice **único composto** com `gateway` (`[gateway, gateway_id]`) — dois gateways podem reusar o mesmo id |
| `amount` | `integer` | centavos — valor total desta tentativa |
| `platform_fee` | `integer` | centavos — comissão da Boon (vC) |
| `amount_to_producer` | `integer` | centavos — repassado ao produtor = `amount - platform_fee` (vT − vC). ⚠️ nome de coluna ainda a definir |
| `interest` | `integer` | centavos — juros de parcelamento. ⚠️ **Aberto**: reconciliar com `platform_fee`/`amount_to_producer` — ainda não ficou explícito se juros é parte da comissão ou uma quarta fatia separada |
| `status` | `string` (enum) | status **desta tentativa específica** (não do pedido): ex. `pending`, `processing`, `paid`, `failed`, `chargedback`, `refunded` |
| `failure_reason` | `string`/`text` | nullable — logado quando a tentativa falha |
| `processed_at` | `datetime` | nullable |

Relações: `belongs_to :order`

---

## Regras de negócio registradas (ADR-0009, ver `PROJECT.md`)

- `Order.status` = status do pedido como um todo; `Payment.status` = status de uma tentativa
  específica de gateway. Um Order pode ter N Payments.
- Depois de **3 falhas** na mesma tentativa/gateway, marca aquele `Payment` como `failed`, loga o
  motivo, e tenta em **outro gateway** (fallback) — lógica ainda **não implementada** (extensão da
  ADR-0003).
- Índice único composto `[payment.gateway, payment.gateway_id]`.

## Ainda não modelado (futuro — ver "Open reminders" em `PROJECT.md`)

- Entidade `Withdrawal`/`Payout` (saque do produtor) — taxa fixa de R$10,00 por saque.
- Revisar o modelo de negócio da plataforma (comissão, taxa de saque, etc).
