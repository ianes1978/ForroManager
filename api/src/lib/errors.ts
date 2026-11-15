import type { ContentfulStatusCode } from "hono/utils/http-status";

/**
 * Errore applicativo con codice stabile (per l'app) e messaggio in italiano
 * (da mostrare all'utente). Viene trasformato in JSON dal gestore globale.
 */
export class ApiError extends Error {
  readonly status: ContentfulStatusCode;
  readonly code: string;
  readonly details?: unknown;

  constructor(status: ContentfulStatusCode, code: string, message: string, details?: unknown) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

export const unauthorized = (message = "Sessione scaduta o non valida. Accedi di nuovo.") =>
  new ApiError(401, "unauthorized", message);

export const forbidden = (code: string, message: string) => new ApiError(403, code, message);

export const notFound = (message = "Risorsa non trovata.") => new ApiError(404, "not_found", message);

export const conflict = (code: string, message: string) => new ApiError(409, code, message);

export const invalid = (message: string, details?: unknown) =>
  new ApiError(422, "validation_error", message, details);
