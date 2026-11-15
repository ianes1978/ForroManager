# ForroManager

Registro dei pagamenti dell'associazione: soci, quote associative (anno solare) e
mensili, prodotti ed eventi, moduli firmati, incassi e riepiloghi.

Il repository contiene due parti:

| Cartella | Contenuto |
|---|---|
| [`api/`](api/) | Backend REST: Cloudflare Worker in TypeScript con Hono e database D1 |
| [`app/`](app/) | App Flutter per Android, iOS e web (la build web è servita dallo stesso Worker) |

> Le istruzioni complete per avvio locale, migrazioni, deploy e build verranno
> completate tappa per tappa.

## Requisiti

- Node.js 20 o successivo, npm
- Flutter SDK (stabile), Android Studio per Android, Xcode per iOS (solo su Mac)
- Un account Cloudflare (piano Workers Free) solo per il deploy

## Privacy

I dati trattati sono personali (GDPR): il database D1 va creato con giurisdizione
europea, i log del Worker non contengono dati personali e l'app non tiene copie
permanenti dei dati sul dispositivo.
