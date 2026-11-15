-- Migrazione 0005: eliminazione degli utenti.
-- Un utente eliminato non compare più nell'elenco, non può accedere e la sua
-- email torna libera; resta nel database solo il nome, perché lo storico
-- (pagamenti registrati, registro delle modifiche) deve restare completo.
ALTER TABLE users ADD COLUMN deleted_at TEXT;
ALTER TABLE users ADD COLUMN deleted_by INTEGER REFERENCES users(id);
