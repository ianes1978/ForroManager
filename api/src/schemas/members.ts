import { z } from "@hono/zod-openapi";
import { DateSchema, YearMonthSchema } from "../lib/http.ts";

const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .nullable()
    .optional()
    .transform((v) => (v === "" ? null : v));

/** Campi modificabili del socio. Si raccolgono solo i dati essenziali. */
export const MemberInputSchema = z.object({
  firstName: z.string().trim().min(1, "Il nome è obbligatorio.").max(80),
  lastName: z.string().trim().min(1, "Il cognome è obbligatorio.").max(80),
  email: z
    .email("Indirizzo email non valido.")
    .max(254)
    .nullable()
    .optional()
    .or(z.literal("").transform(() => null)),
  phone: optionalText(30).refine((v) => v == null || /^[+0-9 ()./-]{5,30}$/.test(v), "Numero di telefono non valido."),
  joinedOn: DateSchema,
  notes: optionalText(1000),
  annualCategoryId: z.number().int().positive().optional(),
  monthlyCategoryId: z.number().int().positive().optional(),
});

export const CategoryRefSchema = z.object({ id: z.number().int(), name: z.string() });

export const SuspensionSchema = z
  .object({
    id: z.number().int(),
    from: YearMonthSchema,
    to: YearMonthSchema,
    reason: z.string().nullable(),
    createdAt: z.string(),
  })
  .openapi("Suspension");

export const MemberSchema = z
  .object({
    id: z.number().int(),
    firstName: z.string(),
    lastName: z.string(),
    email: z.string().nullable(),
    phone: z.string().nullable(),
    joinedOn: z.string(),
    status: z.enum(["attivo", "cessato"]),
    ceasedOn: z.string().nullable(),
    notes: z.string().nullable(),
    annualCategory: CategoryRefSchema,
    monthlyCategory: CategoryRefSchema,
    createdAt: z.string(),
    updatedAt: z.string(),
  })
  .openapi("Member");

export const MemberDetailSchema = MemberSchema.extend({ suspensions: z.array(SuspensionSchema) }).openapi("MemberDetail");

export interface MemberRow {
  id: number;
  first_name: string;
  last_name: string;
  email: string | null;
  phone: string | null;
  joined_on: string;
  status: "attivo" | "cessato";
  ceased_on: string | null;
  notes: string | null;
  annual_category_id: number;
  annual_category_name: string;
  monthly_category_id: number;
  monthly_category_name: string;
  created_at: string;
  updated_at: string;
}

export const MEMBER_SELECT = `
  SELECT m.id, m.first_name, m.last_name, m.email, m.phone, m.joined_on, m.status, m.ceased_on, m.notes,
         m.annual_category_id, ac.name AS annual_category_name,
         m.monthly_category_id, mc.name AS monthly_category_name,
         m.created_at, m.updated_at
    FROM members m
    JOIN fee_categories ac ON ac.id = m.annual_category_id
    JOIN fee_categories mc ON mc.id = m.monthly_category_id`;

export function toMember(r: MemberRow): z.infer<typeof MemberSchema> {
  return {
    id: r.id,
    firstName: r.first_name,
    lastName: r.last_name,
    email: r.email,
    phone: r.phone,
    joinedOn: r.joined_on,
    status: r.status,
    ceasedOn: r.ceased_on,
    notes: r.notes,
    annualCategory: { id: r.annual_category_id, name: r.annual_category_name },
    monthlyCategory: { id: r.monthly_category_id, name: r.monthly_category_name },
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}

export const MemberSummarySchema = z
  .object({
    arrearsCents: z.number().int(),
    arrearsCount: z.number().int(),
    openChargesCents: z.number().int(),
    openChargesCount: z.number().int(),
    missingForms: z.number().int(),
    inRegola: z.boolean(),
  })
  .openapi("MemberListSummary");

export const MemberListItemSchema = MemberSchema.extend({ summary: MemberSummarySchema }).openapi("MemberListItem");
