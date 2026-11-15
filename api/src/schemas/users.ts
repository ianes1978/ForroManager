import { z } from "@hono/zod-openapi";
import { PASSWORD_MIN_LENGTH } from "../lib/crypto.ts";

export const EmailSchema = z
  .email("Indirizzo email non valido.")
  .max(254)
  .transform((s) => s.trim().toLowerCase())
  .openapi({ example: "roberta@esempio.it" });

export const NewPasswordSchema = z
  .string()
  .min(PASSWORD_MIN_LENGTH, `La password deve avere almeno ${PASSWORD_MIN_LENGTH} caratteri.`)
  .max(200, "La password è troppo lunga.")
  .openapi({ example: "una-frase-lunga-e-facile" });

export const UserSchema = z
  .object({
    id: z.number().int(),
    email: z.string(),
    name: z.string(),
    active: z.boolean(),
    mustChangePassword: z.boolean(),
    createdAt: z.string(),
    updatedAt: z.string(),
  })
  .openapi("User");

export const SessionUserSchema = z
  .object({
    id: z.number().int(),
    email: z.string(),
    name: z.string(),
    mustChangePassword: z.boolean(),
  })
  .openapi("SessionUser");

export interface UserRow {
  id: number;
  email: string;
  name: string;
  active: number;
  must_change_password: number;
  created_at: string;
  updated_at: string;
}

export const USER_COLUMNS = "id, email, name, active, must_change_password, created_at, updated_at";

export function toUser(r: UserRow): z.infer<typeof UserSchema> {
  return {
    id: r.id,
    email: r.email,
    name: r.name,
    active: r.active === 1,
    mustChangePassword: r.must_change_password === 1,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}
