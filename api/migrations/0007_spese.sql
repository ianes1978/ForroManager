-- Migrazione 0007: spese dell'associazione.
--  * expense_categories: categorie modificabili (affitto sala, maestri...);
--  * expenses: ogni spesa con data, descrizione, importo, categoria e, se pagata
--    dalla cassa, il metodo. Se l'ha anticipata qualcuno si salva solo il suo nome
--    (advanced_by) e la data in cui è stato rimborsato. has_receipt indica se
--    abbiamo la ricevuta.
CREATE TABLE expense_categories (
  id          INTEGER PRIMARY KEY,
  name        TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT    NOT NULL
);

INSERT INTO expense_categories (name, sort_order, created_at) VALUES
  ('Affitto sala', 1, '2026-01-01T00:00:00Z'),
  ('Maestri e workshop', 2, '2026-01-01T00:00:00Z'),
  ('Materiale e merce', 3, '2026-01-01T00:00:00Z'),
  ('Eventi e feste', 4, '2026-01-01T00:00:00Z'),
  ('Commissioni e banca', 5, '2026-01-01T00:00:00Z'),
  ('Altro', 6, '2026-01-01T00:00:00Z');

CREATE TABLE expenses (
  id             INTEGER PRIMARY KEY,
  spent_on       TEXT    NOT NULL,
  description    TEXT    NOT NULL,
  amount_cents   INTEGER NOT NULL CHECK (amount_cents > 0),
  category_id    INTEGER NOT NULL REFERENCES expense_categories(id),
  method_id      INTEGER REFERENCES payment_methods(id),
  advanced_by    TEXT,
  reimbursed_on  TEXT,
  has_receipt    INTEGER NOT NULL DEFAULT 0 CHECK (has_receipt IN (0, 1)),
  note           TEXT,
  created_at     TEXT    NOT NULL,
  created_by     INTEGER NOT NULL REFERENCES users(id),
  updated_at     TEXT    NOT NULL,
  CHECK (reimbursed_on IS NULL OR advanced_by IS NOT NULL)
);
CREATE INDEX idx_expenses_spent_on ON expenses(spent_on);
CREATE INDEX idx_expenses_to_reimburse ON expenses(spent_on) WHERE advanced_by IS NOT NULL AND reimbursed_on IS NULL;
