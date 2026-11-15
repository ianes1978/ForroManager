import { OpenAPIHono, z } from "@hono/zod-openapi";
import { invalid } from "./errors.ts";

export interface SessionUser {
  id: number;
  email: string;
  name: string;
  mustChangePassword: boolean;
}

export type AppEnv = {
  Bindings: Env;
  Variables: { user: SessionUser; sessionId: number };
};

/** Router con validazione uniforme: errori di input → 422 con elenco dei campi. */
export function createRouter() {
  return new OpenAPIHono<AppEnv>({
    defaultHook: (result) => {
      if (!result.success) {
        const fields = result.error.issues.map((i) => ({ field: i.path.join("."), message: i.message }));
        throw invalid("Alcuni dati non sono validi. Controlla i campi evidenziati.", fields);
      }
    },
  });
}

export const ErrorSchema = z
  .object({
    error: z.object({
      code: z.string().openapi({ example: "unauthorized" }),
      message: z.string().openapi({ example: "Sessione scaduta o non valida. Accedi di nuovo." }),
      details: z.unknown().optional(),
    }),
  })
  .openapi("Error");

const errorResponse = (description: string) => ({
  content: { "application/json": { schema: ErrorSchema } },
  description,
});

/** Risposte di errore comuni alle rotte protette. */
export const commonErrors = {
  401: errorResponse("Non autenticato o sessione scaduta"),
  403: errorResponse("Operazione non consentita"),
  422: errorResponse("Dati non validi"),
} as const;

export const errors = {
  404: errorResponse("Risorsa non trovata"),
  409: errorResponse("Conflitto con lo stato attuale"),
  429: errorResponse("Troppi tentativi"),
} as const;

export const bearer = [{ Bearer: [] }];

export const IdParam = z.object({
  id: z.coerce
    .number()
    .int()
    .positive()
    .openapi({ param: { name: "id", in: "path" }, example: 1 }),
});

/** Corpo o risposta JSON con lo schema indicato (abbreviazione per createRoute). */
export const json = <T extends z.ZodType>(schema: T) => ({ content: { "application/json": { schema } } });

export const DateSchema = z.iso.date("Data non valida (formato AAAA-MM-GG).").openapi({ example: "2026-11-15" });

export const YearMonthSchema = z
  .string()
  .regex(/^\d{4}-(0[1-9]|1[0-2])$/, "Mese non valido (formato AAAA-MM).")
  .openapi({ example: "2026-07" });

export const YearSchema = z.coerce.number().int().min(2000).max(2100).openapi({ example: 2026 });

/** Header facoltativo per ripetere un'operazione senza registrarla due volte. */
export const IdempotencyHeaders = z.object({
  "idempotency-key": z
    .string()
    .optional()
    .openapi({
      param: { name: "idempotency-key", in: "header" },
      description: "Valore casuale (16-100 caratteri) generato dal client per questa operazione e riusato nei tentativi successivi.",
      example: "3f9c2b7e8a1d4c6f9e0b2a5d7c8e1f40",
    }),
});

/** Header facoltativo per non sovrascrivere modifiche fatte da altri nel frattempo. */
export const IfMatchHeaders = z.object({
  "if-match": z
    .string()
    .optional()
    .openapi({
      param: { name: "if-match", in: "header" },
      description: 'Il valore updatedAt letto (o "none" se il dato non esisteva). Se nel frattempo è cambiato la risposta è 409 "stale".',
      example: "2026-11-15T10:42:00Z",
    }),
});
