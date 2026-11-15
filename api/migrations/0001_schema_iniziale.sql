-- Migrazione 0001: schema iniziale di ForroManager.
-- Convenzioni:
--   * importi in centesimi di euro, sempre INTEGER;
--   * date come testo ISO 8601 ('YYYY-MM-DD'), istanti come 'YYYY-MM-DDTHH:MM:SSZ' (UTC);
--   * mesi come interi 1..12;
--   * nessuna cancellazione fisica di pagamenti e quote: si annullano lasciando traccia.


-- ---------------------------------------------------------------------------
-- Utenti dell'app (membri del direttivo). Un solo ruolo: tutti possono tutto.
-- ---------------------------------------------------------------------------
CREATE TABLE users (
  id                    INTEGER PRIMARY KEY,
  email                 TEXT    NOT NULL UNIQUE COLLATE NOCASE,
  name                  TEXT    NOT NULL,
  password_hash         TEXT    NOT NULL,           -- base64url
  password_salt         TEXT    NOT NULL,           -- base64url
  password_iterations   INTEGER NOT NULL,
  must_change_password  INTEGER NOT NULL DEFAULT 1 CHECK (must_change_password IN (0, 1)),
  active                INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  created_at            TEXT    NOT NULL,
  updated_at            TEXT    NOT NULL
);

-- Sessioni: si salva solo l'hash SHA-256 del token, mai il token in chiaro.
CREATE TABLE sessions (
  id            INTEGER PRIMARY KEY,
  token_hash    TEXT    NOT NULL UNIQUE,
  user_id       INTEGER NOT NULL REFERENCES users(id),
  created_at    TEXT    NOT NULL,
  expires_at    TEXT    NOT NULL,
  last_used_at  TEXT    NOT NULL,
  revoked_at    TEXT
);
CREATE INDEX idx_sessions_user ON sessions(user_id);

-- Tentativi di login, per il blocco dopo troppi errori.
-- L'email non è salvata in chiaro: solo un suo hash.
CREATE TABLE login_attempts (
  id            INTEGER PRIMARY KEY,
  email_hash    TEXT    NOT NULL,
  attempted_at  TEXT    NOT NULL,
  success       INTEGER NOT NULL CHECK (success IN (0, 1))
);
CREATE INDEX idx_login_attempts_email_time ON login_attempts(email_hash, attempted_at);

-- ---------------------------------------------------------------------------
-- Tariffe
-- ---------------------------------------------------------------------------
-- Categoria di tariffa, stabile negli anni (es. "Associativa ordinaria",
-- "Associativa ridotta", "Mensile ordinaria", "Pacchetto 3 mesi").
CREATE TABLE fee_categories (
  id          INTEGER PRIMARY KEY,
  kind        TEXT    NOT NULL CHECK (kind IN ('annuale', 'mensile', 'pacchetto')),
  name        TEXT    NOT NULL,
  months      INTEGER CHECK (months IS NULL OR months BETWEEN 2 AND 12),  -- solo pacchetti
  active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  created_at  TEXT    NOT NULL,
  UNIQUE (kind, name),
  CHECK ((kind = 'pacchetto') = (months IS NOT NULL))
);

-- Importo di una categoria per un anno solare.
CREATE TABLE fee_rates (
  id            INTEGER PRIMARY KEY,
  category_id   INTEGER NOT NULL REFERENCES fee_categories(id),
  year          INTEGER NOT NULL CHECK (year BETWEEN 2000 AND 2100),
  amount_cents  INTEGER NOT NULL CHECK (amount_cents >= 0),
  updated_at    TEXT    NOT NULL,
  UNIQUE (category_id, year)
);

-- ---------------------------------------------------------------------------
-- Soci
-- ---------------------------------------------------------------------------
CREATE TABLE members (
  id                    INTEGER PRIMARY KEY,
  first_name            TEXT    NOT NULL,
  last_name             TEXT    NOT NULL,
  email                 TEXT,
  phone                 TEXT,
  joined_on             TEXT    NOT NULL,
  status                TEXT    NOT NULL DEFAULT 'attivo' CHECK (status IN ('attivo', 'cessato')),
  ceased_on             TEXT,
  notes                 TEXT,
  annual_category_id    INTEGER NOT NULL REFERENCES fee_categories(id),
  monthly_category_id   INTEGER NOT NULL REFERENCES fee_categories(id),
  created_at            TEXT    NOT NULL,
  created_by            INTEGER NOT NULL REFERENCES users(id),
  updated_at            TEXT    NOT NULL,
  updated_by            INTEGER NOT NULL REFERENCES users(id),
  CHECK ((status = 'cessato') = (ceased_on IS NOT NULL))
);
CREATE INDEX idx_members_name ON members(last_name COLLATE NOCASE, first_name COLLATE NOCASE);

-- Sospensioni: nei mesi sospesi non si generano quote mensili.
-- I mesi sono espressi come numero assoluto year*12 + (month-1), estremi inclusi.
CREATE TABLE member_suspensions (
  id            INTEGER PRIMARY KEY,
  member_id     INTEGER NOT NULL REFERENCES members(id),
  from_period   INTEGER NOT NULL,
  to_period     INTEGER NOT NULL,
  reason        TEXT,
  created_at    TEXT    NOT NULL,
  created_by    INTEGER NOT NULL REFERENCES users(id),
  cancelled_at  TEXT,
  cancelled_by  INTEGER REFERENCES users(id),
  CHECK (to_period >= from_period)
);
CREATE INDEX idx_suspensions_member ON member_suspensions(member_id);

-- ---------------------------------------------------------------------------
-- Prodotti ed eventi (stage, magliette, serate...)
-- ---------------------------------------------------------------------------
CREATE TABLE products (
  id            INTEGER PRIMARY KEY,
  name          TEXT    NOT NULL,
  type          TEXT    NOT NULL CHECK (type IN ('stage', 'evento', 'merchandising', 'altro')),
  price_cents   INTEGER NOT NULL CHECK (price_cents >= 0),
  active        INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  created_at    TEXT    NOT NULL,
  updated_at    TEXT    NOT NULL
);

-- ---------------------------------------------------------------------------
-- Quote e addebiti dovuti dal socio
-- ---------------------------------------------------------------------------
-- kind = 'annuale'  : quota associativa dell'anno solare (month NULL)
-- kind = 'mensile'  : quota del mese (month 1..12)
-- kind = 'prodotto' : addebito di un prodotto o evento (product_id)
-- base_amount_cents è l'importo da tariffa; amount_cents quello effettivo,
-- diverso solo se c'è una riduzione (adjustment_reason obbligatorio).
CREATE TABLE dues (
  id                  INTEGER PRIMARY KEY,
  member_id           INTEGER NOT NULL REFERENCES members(id),
  kind                TEXT    NOT NULL CHECK (kind IN ('annuale', 'mensile', 'prodotto')),
  year                INTEGER NOT NULL,
  month               INTEGER CHECK (month IS NULL OR month BETWEEN 1 AND 12),
  category_id         INTEGER REFERENCES fee_categories(id),
  product_id          INTEGER REFERENCES products(id),
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
  CHECK (amount_cents = base_amount_cents OR adjustment_reason IS NOT NULL)
);
-- Una sola quota attiva per socio e periodo: la generazione è idempotente.
CREATE UNIQUE INDEX uq_dues_period
  ON dues(member_id, kind, year, COALESCE(month, 0))
  WHERE kind <> 'prodotto' AND cancelled_at IS NULL;
CREATE INDEX idx_dues_member ON dues(member_id, year);

-- ---------------------------------------------------------------------------
-- Pagamenti
-- ---------------------------------------------------------------------------
CREATE TABLE payment_methods (
  id          INTEGER PRIMARY KEY,
  code        TEXT    NOT NULL UNIQUE,
  label       TEXT    NOT NULL,
  active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  sort_order  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE payments (
  id            INTEGER PRIMARY KEY,
  member_id     INTEGER NOT NULL REFERENCES members(id),
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
CREATE INDEX idx_payments_member ON payments(member_id);
CREATE INDEX idx_payments_paid_on ON payments(paid_on);

-- Ripartizione di un pagamento su una o più quote (es. tre mesi insieme).
-- La somma delle righe è uguale all'importo del pagamento.
CREATE TABLE payment_allocations (
  id            INTEGER PRIMARY KEY,
  payment_id    INTEGER NOT NULL REFERENCES payments(id),
  due_id        INTEGER NOT NULL REFERENCES dues(id),
  amount_cents  INTEGER NOT NULL CHECK (amount_cents > 0),
  UNIQUE (payment_id, due_id)
);
CREATE INDEX idx_allocations_due ON payment_allocations(due_id);

-- ---------------------------------------------------------------------------
-- Moduli consegnati e restituiti firmati
-- ---------------------------------------------------------------------------
CREATE TABLE forms (
  id          INTEGER PRIMARY KEY,
  name        TEXT    NOT NULL UNIQUE,
  required    INTEGER NOT NULL DEFAULT 0 CHECK (required IN (0, 1)),
  active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  created_at  TEXT    NOT NULL
);

CREATE TABLE member_forms (
  id            INTEGER PRIMARY KEY,
  member_id     INTEGER NOT NULL REFERENCES members(id),
  form_id       INTEGER NOT NULL REFERENCES forms(id),
  delivered_on  TEXT    NOT NULL,
  returned_on   TEXT,
  updated_at    TEXT    NOT NULL,
  updated_by    INTEGER NOT NULL REFERENCES users(id),
  UNIQUE (member_id, form_id)
);

-- ---------------------------------------------------------------------------
-- Registro delle modifiche
-- ---------------------------------------------------------------------------
CREATE TABLE audit_log (
  id          INTEGER PRIMARY KEY,
  at          TEXT    NOT NULL,
  user_id     INTEGER REFERENCES users(id),
  action      TEXT    NOT NULL,   -- create, update, void, cancel, cease, generate, ...
  entity      TEXT    NOT NULL,   -- member, payment, due, fee_rate, ...
  entity_id   INTEGER,
  details     TEXT                -- JSON con i valori prima/dopo
);
CREATE INDEX idx_audit_at ON audit_log(at);
CREATE INDEX idx_audit_entity ON audit_log(entity, entity_id);

-- ---------------------------------------------------------------------------
-- Dati iniziali (configurazione, nessun dato personale)
-- ---------------------------------------------------------------------------
INSERT INTO payment_methods (code, label, sort_order) VALUES
  ('contanti', 'Contanti', 1),
  ('bonifico', 'Bonifico', 2),
  ('paypal',   'PayPal',   3),
  ('altro',    'Altro',    4);

INSERT INTO fee_categories (kind, name, months, created_at) VALUES
  ('annuale', 'Ordinaria', NULL, '2026-01-01T00:00:00Z'),
  ('annuale', 'Ridotta',   NULL, '2026-01-01T00:00:00Z'),
  ('mensile', 'Ordinaria', NULL, '2026-01-01T00:00:00Z');
