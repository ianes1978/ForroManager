/**
 * Primitive crittografiche basate solo su Web Crypto, disponibili sia nei
 * Workers sia in Node.js (usate anche dallo script di creazione utenti).
 *
 * Password: PBKDF2-SHA256 con salt casuale per utente, applicato all'HMAC
 * della password con un "pepe" segreto (secret del Worker, mai nel database).
 * Il numero di iterazioni è salvato per utente, così si può aumentare in futuro.
 */

/**
 * Iterazioni PBKDF2. Valore scelto per restare entro i 10 ms di CPU per
 * richiesta del piano Workers Free (misurato: circa 4-5 ms).
 */
export const PASSWORD_ITERATIONS = 30_000;
export const PASSWORD_MIN_LENGTH = 12;

const encoder = new TextEncoder();

export function toBase64Url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64Url(text: string): Uint8Array {
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export function randomBytes(length: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(length));
}

/** Confronto a tempo costante (non rivela dopo quanti byte i valori differiscono). */
export function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

export async function sha256Base64Url(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
  return toBase64Url(new Uint8Array(digest));
}

async function pepperedPassword(password: string, pepper: string): Promise<ArrayBuffer> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(pepper),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return crypto.subtle.sign("HMAC", key, encoder.encode(password));
}

async function derive(password: string, pepper: string, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
  const base = await crypto.subtle.importKey("raw", await pepperedPassword(password, pepper), "PBKDF2", false, [
    "deriveBits",
  ]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: salt as BufferSource, iterations },
    base,
    256,
  );
  return new Uint8Array(bits);
}

export interface PasswordHash {
  hash: string;
  salt: string;
  iterations: number;
}

export async function hashPassword(
  password: string,
  pepper: string,
  iterations: number = PASSWORD_ITERATIONS,
): Promise<PasswordHash> {
  if (!pepper) throw new Error("PASSWORD_PEPPER non configurato");
  const salt = randomBytes(16);
  const hash = await derive(password, pepper, salt, iterations);
  return { hash: toBase64Url(hash), salt: toBase64Url(salt), iterations };
}

export async function verifyPassword(password: string, pepper: string, stored: PasswordHash): Promise<boolean> {
  if (!pepper) throw new Error("PASSWORD_PEPPER non configurato");
  const hash = await derive(password, pepper, fromBase64Url(stored.salt), stored.iterations);
  return constantTimeEqual(hash, fromBase64Url(stored.hash));
}

/** Token di sessione: 32 byte casuali. Nel database va solo il suo hash. */
export function newSessionToken(): string {
  return toBase64Url(randomBytes(32));
}
