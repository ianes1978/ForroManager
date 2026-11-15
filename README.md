# ForroManager

Registro dei pagamenti dell'associazione: soci, quote associative (anno solare)
e mensili, prodotti ed eventi, moduli firmati, incassi e riepiloghi. È usato in
condivisione dai membri del direttivo (un solo ruolo: tutti possono tutto).

| Cartella | Contenuto |
|---|---|
| [`api/`](api/) | Backend REST: Cloudflare Worker in TypeScript con Hono, database D1 |
| [`app/`](app/) | App Flutter per Android, iOS e web (la build web è servita dallo stesso Worker) |
| [`.github/workflows/`](.github/workflows/) | Test, preparazione di Cloudflare, deploy e build dell'APK |

## Requisiti

- Node.js 22 o successivo e npm
- Flutter SDK stabile (il progetto usa la 3.47), Android Studio per Android,
  Xcode e CocoaPods per iOS (solo su Mac)
- Per il deploy: account Cloudflare (piano Workers Free) e GitHub Actions

---

## Backend (`api/`)

### Avvio locale

```bash
cd api
npm install
cp .dev.vars.example .dev.vars        # poi metti un valore casuale lungo in PASSWORD_PEPPER
npm run db:migrate:local              # crea il database D1 locale e applica le migrazioni
npm run dev                           # API su http://localhost:8787/api/v1
```

Il primo utente si crea con lo script (non esiste registrazione libera):

```bash
node scripts/create-user.ts --email nome@esempio.it --name "Nome" > .user.sql
npx wrangler d1 execute forromanager-db --local --file .user.sql
rm .user.sql
```

Lo script stampa una password temporanea, da cambiare al primo accesso. Gli altri
utenti si creano dall'app (Altro → Utenti).

### Test

```bash
npm run typecheck
npm test
```

I test girano nel runtime dei Workers con un database D1 locale e coprono
login, sessioni, limite ai tentativi, utenti, soci, sospensioni, tariffe,
generazione delle quote, pagamenti (anche su più mesi e con pacchetti),
report, moduli, esportazione CSV e allineamento della specifica OpenAPI.

### Migrazioni

Le migrazioni SQL sono in [`api/migrations/`](api/migrations/), numerate e
applicate in ordine. Per crearne una nuova:

```bash
npx wrangler d1 migrations create forromanager-db descrizione_breve
npm run db:migrate:local
```

In produzione vengono applicate dal workflow di deploy
(`wrangler d1 migrations apply forromanager-db --remote`).

### Specifica OpenAPI

La specifica è generata dalle stesse definizioni usate per validare le richieste:

- dal vivo su `/api/v1/openapi.json`;
- salvata in [`api/openapi.json`](api/openapi.json): dopo aver cambiato una rotta
  esegui `npm run openapi` (un test fallisce se il file non è aggiornato).

### Scelte principali

- **Importi** sempre in centesimi interi. **Date** in formato ISO.
- **Password**: PBKDF2-SHA256 (Web Crypto) con salt per utente e un "pepe"
  segreto (`PASSWORD_PEPPER`, secret del Worker, mai nel database). 30.000
  iterazioni per restare entro i 10 ms di CPU del piano gratuito; le iterazioni
  sono salvate per utente e l'hash si aggiorna da solo se vengono aumentate.
- **Sessioni**: token casuale, nel database solo il suo hash; durata 30 giorni
  rinnovata con l'uso; revocabili. Blocco di 15 minuti dopo 5 errori di login.
- **Pagamenti** mai cancellati: si annullano con un motivo. Ogni modifica
  finisce nel registro (`audit_log`).
- **Privacy**: database con giurisdizione UE, nessun dato personale nei log,
  CSV con `Cache-Control: no-store`.
- **Limiti del piano gratuito**: le operazioni su molti soci (generazione
  delle quote, riepiloghi) usano una sola query SQL, per restare sotto le 50
  query per richiesta.

---

## Deploy su Cloudflare (da GitHub Actions)

Nomi usati sull'account: Worker **`forromanager-api`**, database **`forromanager-db`**.
L'indirizzo finale sarà `https://forromanager-api.<tuo-sottodominio>.workers.dev`.

1. **Token Cloudflare**: nel pannello Cloudflare crea un API token con i permessi
   *Account → Workers Scripts → Edit* e *Account → D1 → Edit*.
2. **Secret del repository GitHub** (Settings → Secrets and variables → Actions):
   - `CLOUDFLARE_API_TOKEN`: il token del punto 1;
   - `CLOUDFLARE_ACCOUNT_ID`: l'id dell'account (pannello Cloudflare, colonna destra);
   - `PASSWORD_PEPPER`: una stringa casuale lunga (non cambiarla più: invaliderebbe le password).
3. **Preparazione**: in Actions avvia a mano *Cloudflare - preparazione*. Crea il
   database con giurisdizione UE e mostra il suo id nel riepilogo del job.
4. **Variabile del repository** `D1_DATABASE_ID` con l'id del punto 3.
5. **Deploy**: avvia a mano il workflow di deploy (vedi la sezione dell'app).
