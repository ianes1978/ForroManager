# ForroManager

Registro dei pagamenti dell'associazione: soci, tessera annuale (anno solare),
corsi a periodi di durata libera (mese, trimestre, quadrimestre...) con iscrizioni,
quote mensili, prodotti ed eventi (anche venduti a non soci), magazzino con taglie
e colori, moduli firmati, incassi, riepiloghi e report Excel. È usato in
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
- **Pagamenti** mai cancellati: si correggono (data, metodo, nota, importo, voci
  e socio, con `If-Match`) oppure si annullano con un motivo se registrati per
  errore. Ogni modifica finisce nel registro (`audit_log`) con il prima e il dopo.
- **Corsi e periodi** si eliminano solo se non hanno iscritti né pagamenti
  (ad esempio creati per sbaglio); altrimenti si disattivano.
- **Magazzino**: le scorte sono la somma dei movimenti (carichi, vendite, resi,
  rettifiche), per variante di prodotto. Una vendita scala la scorta, l'annullamento
  la rimette. Si può vendere oltre la scorta: l'app avvisa e la scorta va in negativo.
- **Corsi e periodi**: ogni corso (es. Forró, Zouk) ha periodi con prezzo proprio;
  iscrivere un socio a un periodo crea la sua quota (`dues.kind = 'periodo'`), che
  conta per gli arretrati dal mese di inizio. Un socio può seguire più corsi.
- **Report Excel**: l'API fornisce i dati (`/reports/full`), il file `.xlsx` è
  generato dall'app (pacchetto `excel`), così il Worker resta nei limiti di CPU.
- **Più utenti insieme**: i dati stanno solo nel database e ogni salvataggio è
  una transazione. Incassi e vendite accettano l'header `Idempotency-Key`: se la
  rete cade dopo il salvataggio e si riprova, l'operazione non viene registrata
  due volte (le chiavi durano 24 ore). Le modifiche di soci, prodotti, utenti e
  tariffe accettano `If-Match` con la versione letta (`updatedAt`): se nel
  frattempo un altro ha salvato, la risposta è 409 `stale` con chi ha modificato,
  invece di sovrascrivere. L'app usa entrambi.
- **Senza rete** l'app mostra un messaggio chiaro con "Riprova" e non salva nulla
  sul telefono.
- **Vendite a non soci**: se pagate subito non si registra alcun dato
  dell'acquirente; se pagate più tardi solo il nome, cancellato quando la vendita
  è saldata. Annullare il pagamento di una vendita a non socio annulla anche la
  vendita. Nei movimenti di magazzino e nel CSV del magazzino ogni vendita indica
  a chi è andata (socio o "non socio"), anche dopo che il nome è stato cancellato.
- **Privacy**: database con giurisdizione UE, nessun dato personale nei log,
  CSV con `Cache-Control: no-store`.
- **Limiti del piano gratuito**: le operazioni su molti soci (generazione
  delle quote, riepiloghi) usano una sola query SQL, per restare sotto le 50
  query per richiesta.

---

## App (`app/`)

Flutter, interfaccia in italiano pensata per l'uso con una mano (barra in basso,
pulsante **Incassa** sotto il pollice). Stato gestito con **Riverpod**: un solo
modello per tutta l'app, con caricamento/errore gestiti in modo uniforme e
provider facili da sostituire nei test.

### Indirizzo del backend per ambiente

L'indirizzo non è scritto nel codice: si passa in compilazione con un file in
[`app/config/`](app/config/).

| File | Uso |
|---|---|
| `config/local.json` | app web o iOS Simulator con il backend locale (`http://localhost:8787`) |
| `config/android-emulator.json` | emulatore Android (`http://10.0.2.2:8787`) |
| `config/prod.json` | produzione: copia `prod.example.json` e metti l'indirizzo del Worker (escluso da git) |

La build web servita dal Worker non ha bisogno dell'indirizzo: usa la stessa origine.

### Avvio locale

Con il backend avviato (`cd api && npm run dev`):

```bash
cd app
flutter pub get
flutter run -d chrome --dart-define-from-file=config/local.json --web-port 5173
```

Per l'app web servita da un'altra porta, abilita CORS in sviluppo impostando
`DEV_CORS_ORIGIN=http://localhost:5173` in `api/.dev.vars`.

Su emulatore Android: `flutter run --dart-define-from-file=config/android-emulator.json`.

### Test

```bash
flutter analyze
flutter test
```

### Build

```bash
# Android (APK)
flutter build apk --release --dart-define-from-file=config/prod.json

# iOS (su Mac con Xcode; firma con il proprio Apple ID in Xcode)
flutter build ipa --release --dart-define-from-file=config/prod.json

# Web, da servire come file statici dal Worker
flutter build web --release --no-web-resources-cdn
cp -r build/web/. ../api/public/
```

**Firma Android**: senza configurazione l'APK di rilascio usa la chiave di debug.
Per una chiave stabile crea un keystore (mai nel repository):

```bash
keytool -genkey -v -keystore ~/forromanager-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias forromanager
```

e, in locale, un file `app/android/key.properties` (escluso da git) con
`storeFile`, `storePassword`, `keyAlias`, `keyPassword`. In GitHub Actions si
usano invece i secret `ANDROID_KEYSTORE_BASE64` (il file `.jks` in base64),
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.

### Privacy sul dispositivo

- Il token di sessione è nell'archivio sicuro (Keychain/Keystore); sul web resta
  solo in memoria e ricaricando la pagina si rifà l'accesso.
- Nessuna copia locale dei dati: tutto viene letto dall'API al momento.
- I CSV esportati passano da una cartella temporanea al menu Condividi e poi
  vengono cancellati.

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
5. **Deploy**: avvia a mano *Cloudflare - deploy*. Esegue i test, compila l'app
   web, applica le migrazioni al database remoto e pubblica il Worker. Il
   riepilogo del job mostra l'indirizzo `https://forromanager-api.<sottodominio>.workers.dev`.
6. **Primo utente**: avvia a mano *Cloudflare - primo utente* con email, nome e
   password temporanea. Funziona solo se il database non ha ancora utenti; al
   primo accesso l'app obbliga a cambiare la password.
7. **APK**: imposta la variabile del repository `API_BASE_URL` con l'indirizzo del
   punto 5. Il workflow *App - APK Android* parte a ogni push che tocca `app/`
   (o a mano) e pubblica l'APK come pre-release del repository.

I workflow avviati a mano compaiono in Actions solo se sono nel ramo predefinito
del repository.
