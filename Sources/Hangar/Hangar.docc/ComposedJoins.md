# Joins wider than three tables

`Table.query { }` builds a join of any width by name instead of by position.

## Overview

``JoinedQuery`` and ``JoinedQuery3`` fix the join count in the type itself, so
a fourth table would need a fourth struct and a fourth copy of the whole
method surface — and every composition closure downstream takes one positional
argument per table. At three tables `{ _, comment, author in ... }` is already
the ergonomic ceiling; at five it is bookkeeping.

``QueryBuilder`` hands each joined table back as an ordinary Swift value:

```swift
let report = try await repo.all(
    Order.query { q, order in
        let customer = q.join(Customer.self) { $0.id == order.customerID }
        let item = q.join(OrderItem.self) { $0.orderID == order.id }
        let product = q.join(Product.self) { $0.id == item.productID }
        q.where(customer.active)
        return q.select(into: OrderReport.self) {
            (id: order.id, customer: customer.name, product: product.name)
        }
    })
```

Five joins read as five `let` bindings, and every later predicate refers to a
table by name.

## Two type parameters, however many tables

``ComposedQuery`` is `ComposedQuery<Base, Result>` whether it joins two tables
or seven. `SQLExpression` and `OrderTerm` carry only table/column *name
strings*, so once a join's ON-predicate is built, nothing about rendering
needs the joined Swift type. The join list is erased into an array of clauses;
what stays fully typed is the builder.

Two things do not survive erasure and are captured eagerly at `q.join` time:
the joined table's quoted name, and its `@Deleted` column if it has one — the
second so the deleted-row scope can be applied to a joined source.

## Self-joins need no alias

Every `q.join` mints a fresh alias (`t1`, `t2`, ...), so joining the same table
twice — or joining the base back to itself — is ordinary. There is no
ambiguity guard because collision is impossible by construction, which is what
`.alias("child")` bought by hand on the fixed-arity forms.

## The snapshot point

`q.query()` and `q.select`/`q.select(into:)` snapshot the builder. A mutation
after one of them would change nothing about the query already produced, so
Hangar traps rather than ignoring it — a silent no-op is the kind of bug this
package refuses elsewhere. Compose first, produce last.

## What it shares with the fixed-arity forms

`where`/`orWhere`/`order`/`groupBy`/`having`/`limit`/`offset`/`distinct`, both
`select` shapes, `repo.all`/`one`/`count`/`exists` (with the same
changes-what-a-row-is subquery rules), row locks, preloads on the base-entity
path, and the soft-delete scope.

``JoinedQuery`` and ``JoinedQuery3`` remain — their closure form is the nicer
spelling for a quick two-table join — but the arity is frozen there. There
will be no `JoinedQuery4`.
