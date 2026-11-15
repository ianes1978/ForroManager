-- Migrazione 0004: corsi con periodi di durata libera.
--  * courses: i corsi (es. "Forró", "Zouk"); un socio può frequentarne più d'uno;
--  * course_periods: periodi di un corso con prezzo proprio (un mese, un trimestre,
--    un quadrimestre...), es. "Forró gen–mar 2026" a 50 €;
--  * dues: nuovo tipo 'periodo' = iscrizione di un socio a un periodo. year e month
--    indicano il mese di inizio del periodo (per ordinamento e arretrati).
-- I dati esistenti restano invariati.

PRAGMA defer_foreign_keys = on;

CREATE TABLE courses (
  id          INTEGER PRIMARY KEY,
  name        TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  created_at  TEXT    NOT NULL,
  updated_at  TEXT    NOT NULL
);

-- I mesi sono numeri assoluti year*12 + (month-1), estremi inclusi.
CREATE TABLE course_periods (
  id            INTEGER PRIMARY KEY,
  course_id     INTEGER NOT NULL REFERENCES courses(id),
  name          TEXT    NOT NULL,
  from_period   INTEGER NOT NULL,
  to_period     INTEGER NOT NULL,
  amount_cents  INTEGER NOT NULL CHECK (amount_cents >= 0),
  active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  created_at    TEXT    NOT NULL,
  updated_at    TEXT    NOT NULL,
  CHECK (to_period >= from_period),
  UNIQUE (course_id, from_period, to_period)
);
CREATE INDEX idx_course_periods_course ON course_periods(course_id, from_period);

-- Ricostruzione di dues (nuovo tipo e nuova colonna) e delle tabelle che la
-- riferiscono, nello stesso ordine sicuro della migrazione 0002.
CREATE TABLE dues_new (
  id                  INTEGER PRIMARY KEY,
  member_id           INTEGER REFERENCES members(id),
  buyer_name          TEXT,
  kind                TEXT    NOT NULL CHECK (kind IN ('annuale', 'mensile', 'periodo', 'prodotto')),
  year                INTEGER NOT NULL,
  month               INTEGER CHECK (month IS NULL OR month BETWEEN 1 AND 12),
  category_id         INTEGER REFERENCES fee_categories(id),
  course_period_id    INTEGER REFERENCES course_periods(id),
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
  CHECK ((kind IN ('mensile', 'periodo')) = (month IS NOT NULL)),
  CHECK ((kind = 'prodotto') = (product_id IS NOT NULL)),
  CHECK ((kind = 'periodo') = (course_period_id IS NOT NULL)),
  CHECK (kind NOT IN ('annuale', 'mensile') OR category_id IS NOT NULL),
  CHECK (amount_cents = base_amount_cents OR adjustment_reason IS NOT NULL),
  CHECK (member_id IS NOT NULL OR kind = 'prodotto'),
  CHECK (buyer_name IS NULL OR member_id IS NULL),
  CHECK (variant_id IS NULL OR kind = 'prodotto')
);
INSERT INTO dues_new (id, member_id, buyer_name, kind, year, month, category_id, product_id, variant_id, quantity,
                      base_amount_cents, amount_cents, adjustment_reason, charged_on, created_at, created_by,
                      cancelled_at, cancelled_by, cancel_reason)
  SELECT id, member_id, buyer_name, kind, year, month, category_id, product_id, variant_id, quantity,
         base_amount_cents, amount_cents, adjustment_reason, charged_on, created_at, created_by,
         cancelled_at, cancelled_by, cancel_reason
    FROM dues;

CREATE TABLE payment_allocations_new (
  id            INTEGER PRIMARY KEY,
  payment_id    INTEGER NOT NULL REFERENCES payments(id),
  due_id        INTEGER NOT NULL REFERENCES dues_new(id),
  amount_cents  INTEGER NOT NULL CHECK (amount_cents > 0),
  UNIQUE (payment_id, due_id)
);
INSERT INTO payment_allocations_new SELECT id, payment_id, due_id, amount_cents FROM payment_allocations;

CREATE TABLE stock_movements_new (
  id          INTEGER PRIMARY KEY,
  variant_id  INTEGER NOT NULL REFERENCES product_variants(id),
  kind        TEXT    NOT NULL CHECK (kind IN ('carico', 'vendita', 'reso', 'rettifica')),
  quantity    INTEGER NOT NULL CHECK (quantity <> 0),
  due_id      INTEGER REFERENCES dues_new(id),
  moved_on    TEXT    NOT NULL,
  note        TEXT,
  created_at  TEXT    NOT NULL,
  created_by  INTEGER NOT NULL REFERENCES users(id),
  CHECK ((kind IN ('vendita', 'reso')) = (due_id IS NOT NULL))
);
INSERT INTO stock_movements_new SELECT id, variant_id, kind, quantity, due_id, moved_on, note, created_at, created_by FROM stock_movements;

DROP TABLE payment_allocations;
DROP TABLE stock_movements;
DROP TABLE dues;
ALTER TABLE dues_new RENAME TO dues;
ALTER TABLE payment_allocations_new RENAME TO payment_allocations;
ALTER TABLE stock_movements_new RENAME TO stock_movements;

-- Una sola quota attiva per socio e periodo (annuale/mensile) o per socio e periodo di corso.
CREATE UNIQUE INDEX uq_dues_period
  ON dues(member_id, kind, year, COALESCE(month, 0))
  WHERE kind IN ('annuale', 'mensile') AND cancelled_at IS NULL;
CREATE UNIQUE INDEX uq_dues_course_period
  ON dues(member_id, course_period_id)
  WHERE kind = 'periodo' AND cancelled_at IS NULL;
CREATE INDEX idx_dues_member ON dues(member_id, year);
CREATE INDEX idx_dues_non_member ON dues(charged_on) WHERE member_id IS NULL;
CREATE INDEX idx_dues_course_period ON dues(course_period_id) WHERE kind = 'periodo';
CREATE INDEX idx_allocations_due ON payment_allocations(due_id);
CREATE INDEX idx_stock_variant ON stock_movements(variant_id);
