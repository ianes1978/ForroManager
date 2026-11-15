-- Migrazione 0003: protezione dai doppi salvataggi.
-- Ogni operazione di incasso o vendita può arrivare con una chiave unica
-- (header Idempotency-Key). Se la stessa chiave arriva di nuovo, ad esempio
-- perché la rete è caduta dopo il salvataggio e l'utente riprova, il server
-- restituisce la risposta già data senza registrare di nuovo.
-- Le chiavi vengono eliminate dopo 24 ore.
CREATE TABLE idempotency_keys (
  key            TEXT    PRIMARY KEY,
  user_id        INTEGER NOT NULL REFERENCES users(id),
  route          TEXT    NOT NULL,
  status_code    INTEGER,          -- NULL finché l'operazione è in corso
  response_body  TEXT,
  created_at     TEXT    NOT NULL
);
CREATE INDEX idx_idempotency_created ON idempotency_keys(created_at);
