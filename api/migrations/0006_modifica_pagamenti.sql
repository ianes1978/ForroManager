-- Migrazione 0006: i pagamenti si possono correggere (data, metodo, nota, importo,
-- socio e voci pagate). updated_at è la versione usata per il controllo delle
-- modifiche in contemporanea (If-Match); il registro conserva il prima e il dopo.
ALTER TABLE payments ADD COLUMN updated_at TEXT;
UPDATE payments SET updated_at = COALESCE(voided_at, created_at);
