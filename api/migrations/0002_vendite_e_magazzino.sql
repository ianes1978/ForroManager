-- Migrazione 0002: vendite a non soci e magazzino con varianti.
--  * products: indica se il prodotto ha scorte e la soglia di "scorta bassa";
--  * product_variants: varianti (taglia, colore) di un prodotto con scorte;
--  * stock_movements: carichi, vendite, resi e rettifiche (la scorta è la somma);
--  * dues e payments: il socio diventa facoltativo per le vendite di prodotti
--    a chi non è iscritto; dell'acquirente si salva solo il nome, e solo se
--    paga più tardi (minimizzazione dei dati, GDPR).
-- I dati esistenti restano invariati.

-- Le tabelle dues, payments e payment_allocations vengono ricostruite (SQLite non
-- permette di togliere un NOT NULL): le chiavi esterne si verificano a fine transazione.
PRAGMA defer_foreign_keys = on;

ALTER TABLE products ADD COLUMN tracks_stock INTEGER NOT NULL DEFAULT 0 CHECK (tracks_stock IN (0, 1));
ALTER TABLE products ADD COLUMN low_stock_threshold INTEGER NOT NULL DEFAULT 2 CHECK (low_stock_threshold >= 0);

CREATE TABLE product_variants (
  id          INTEGER PRIMARY KEY,
  product_id  INTEGER NOT NULL REFERENCES products(id),
  size        TEXT    NOT NULL DEFAULT '',   -- taglia, vuota se non serve
  color       TEXT    NOT NULL DEFAULT '',   -- colore, vuoto se non serve
  active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  created_at  TEXT    NOT NULL,
  UNIQUE (product_id, size, color)
);

-- Quote e addebiti: member_id facoltativo solo per i prodotti venduti a non soci.
CREATE TABLE dues_new (
  id                  INTEGER PRIMARY KEY,
  member_id           INTEGER REFERENCES members(id),
  buyer_name          TEXT,
  kind                TEXT    NOT NULL CHECK (kind IN ('annuale', 'mensile', 'prodotto')),
  year                INTEGER NOT NULL,
  month               INTEGER CHECK (month IS NULL OR month BETWEEN 1 AND 12),
  category_id         INTEGER REFERENCES fee_categories(id),
  product_id          INTEGER REFERENCES products(id),
  variant_id          INTEGER REFERENCES product_variants(id),
  quantity            INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  base_amount_cents   INTEGER NOT NULL CHECK (base_amount_cents >= 0),
  amount_cents        INTEGER NOT NULL CHECK (amount_cents >= 0),
  adjustment_reason   TEXT,
  charged_on          TEXT    NOT NULL,
  created_at          TEXT    NOT NULL,
  created_by          INTEGER NOT NULL REFERENCES users(id),
  cancelled_at        TEXT,
  cancelled_by        INTEGER REFERENCES users(id),
  cancel_reason       TEXT,
  CHECK ((kind = 'mensile') = (month IS NOT NULL)),
  CHECK ((kind = 'prodotto') = (product_id IS NOT NULL)),
  CHECK ((kind = 'prodotto') OR category_id IS NOT NULL),
  CHECK (amount_cents = base_amount_cents OR adjustment_reason IS NOT NULL),
  CHECK (member_id IS NOT NULL OR kind = 'prodotto'),
  CHECK (buyer_name IS NULL OR member_id IS NULL),
  CHECK (variant_id IS NULL OR kind = 'prodotto')
);
INSERT INTO dues_new (id, member_id, kind, year, month, category_id, product_id, base_amount_cents, amount_cents,
                      adjustment_reason, charged_on, created_at, created_by, cancelled_at, cancelled_by, cancel_reason)
  SELECT id, member_id, kind, year, month, category_id, product_id, base_amount_cents, amount_cents,
         adjustment_reason, charged_on, created_at, created_by, cancelled_at, cancelled_by, cancel_reason
    FROM dues;

-- Pagamenti: member_id facoltativo (vendite a non soci).
CREATE TABLE payments_new (
  id            INTEGER PRIMARY KEY,
  member_id     INTEGER REFERENCES members(id),
  paid_on       TEXT    NOT NULL,
  amount_cents  INTEGER NOT NULL CHECK (amount_cents > 0),
  method_id     INTEGER NOT NULL REFERENCES payment_methods(id),
  note          TEXT,
  recorded_by   INTEGER NOT NULL REFERENCES users(id),
  created_at    TEXT    NOT NULL,
  voided_at     TEXT,
  voided_by     INTEGER REFERENCES users(id),
  void_reason   TEXT,
  CHECK ((voided_at IS NULL) = (void_reason IS NULL))
);
INSERT INTO payments_new SELECT id, member_id, paid_on, amount_cents, method_id, note, recorded_by, created_at,
                                voided_at, voided_by, void_reason FROM payments;

-- Le ripartizioni puntano subito alle nuove tabelle: così le vecchie non sono
-- più riferite da nessuno quando vengono eliminate.
CREATE TABLE payment_allocations_new (
  id            INTEGER PRIMARY KEY,
  payment_id    INTEGER NOT NULL REFERENCES payments_new(id),
  due_id        INTEGER NOT NULL REFERENCES dues_new(id),
  amount_cents  INTEGER NOT NULL CHECK (amount_cents > 0),
  UNIQUE (payment_id, due_id)
);
INSERT INTO payment_allocations_new SELECT id, payment_id, due_id, amount_cents FROM payment_allocations;

DROP TABLE payment_allocations;
DROP TABLE payments;
DROP TABLE dues;
-- Il cambio di nome aggiorna anche i riferimenti nelle altre tabelle.
ALTER TABLE dues_new RENAME TO dues;
ALTER TABLE payments_new RENAME TO payments;
ALTER TABLE payment_allocations_new RENAME TO payment_allocations;

CREATE UNIQUE INDEX uq_dues_period
  ON dues(member_id, kind, year, COALESCE(month, 0))
  WHERE kind <> 'prodotto' AND cancelled_at IS NULL;
CREATE INDEX idx_dues_member ON dues(member_id, year);
CREATE INDEX idx_dues_non_member ON dues(charged_on) WHERE member_id IS NULL;
CREATE INDEX idx_payments_member ON payments(member_id);
CREATE INDEX idx_payments_paid_on ON payments(paid_on);
CREATE INDEX idx_allocations_due ON payment_allocations(due_id);

-- Movimenti di magazzino. quantity è positiva per carichi e resi, negativa per
-- le vendite; la rettifica porta la scorta al valore contato.
CREATE TABLE stock_movements (
  id          INTEGER PRIMARY KEY,
  variant_id  INTEGER NOT NULL REFERENCES product_variants(id),
  kind        TEXT    NOT NULL CHECK (kind IN ('carico', 'vendita', 'reso', 'rettifica')),
  quantity    INTEGER NOT NULL CHECK (quantity <> 0),
  due_id      INTEGER REFERENCES dues(id),
  moved_on    TEXT    NOT NULL,
  note        TEXT,
  created_at  TEXT    NOT NULL,
  created_by  INTEGER NOT NULL REFERENCES users(id),
  CHECK ((kind IN ('vendita', 'reso')) = (due_id IS NOT NULL))
);
CREATE INDEX idx_stock_variant ON stock_movements(variant_id);
