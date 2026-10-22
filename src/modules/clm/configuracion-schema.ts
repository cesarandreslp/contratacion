import { z } from "zod";
import { appRole } from "./schema";

// Entrada de los formularios de configuración del CLM (FormData → objetos).
// Ver docs/04-spec-clm-core.md §2 (organigrama, roles con alcance, delegación).

const uuid = z.string().uuid();
const casilla = z.preprocess((v) => v === "on" || v === "true" || v === true, z.boolean());
const opcional = <T extends z.ZodTypeAny>(s: T) => z.preprocess((v) => (v === "" ? undefined : v), s.optional());
const listaComas = (item: z.ZodString) =>
  z.preprocess(
    (v) => String(v ?? "").split(",").map((x) => x.trim()).filter(Boolean),
    z.array(item).min(1, "Indique al menos un valor"),
  );

export const activarClmInput = z.object({
  territorialOrder: z.enum(["NACIONAL", "DEPARTAMENTAL", "DISTRITAL", "MUNICIPAL"]),
  juridicaNombre: z.string().min(3, "Nombre de la oficina jurídica"),
});

export const crearUnidadInput = z.object({
  parentId: opcional(uuid),
  kind: z.enum(["DEPENDENCIA", "AREA", "UNIDAD_CONTRATACION", "JURIDICA_CENTRAL"]),
  code: z.string().regex(/^[A-Z0-9_]{2,30}$/, "Código en mayúsculas, sin espacios (p. ej. SEC_SALUD)"),
  name: z.string().min(3),
});

export const otorgarRolInput = z.object({
  userId: z.string().min(1),
  unitId: uuid,
  role: appRole,
  scope: z.enum(["UNIT", "SUBTREE", "TENANT"]),
});

export const crearDelegacionInput = z.object({
  originUnitId: uuid,
  reviewUnitId: uuid,
  contractTypeId: opcional(uuid),
  minAmount: z.coerce.number().nonnegative().default(0),
});

export const crearTipologiaInput = z.object({
  code: z.string().regex(/^[A-Z0-9_]{2,40}$/, "Código en mayúsculas, sin espacios"),
  name: z.string().min(3),
  requiresSelection: casilla,
  requiresGuarantees: casilla,
  requiredArtifacts: listaComas(z.string().regex(/^[A-Z_]{3,40}$/, "Artefactos en mayúsculas, separados por coma")),
});

export const crearPlanInput = z.object({ fiscalYear: z.coerce.number().int().min(2020).max(2100) });

export const agregarItemPaaInput = z.object({
  planId: uuid,
  unitId: uuid,
  code: z.string().min(1),
  description: z.string().min(5),
  unspscCodes: listaComas(z.string().regex(/^\d{8}$/, "Códigos UNSPSC de 8 dígitos")),
  estimatedValue: z.coerce.number().positive(),
  modality: z.string().min(3),
  expectedStart: z.string().date(),
  durationDays: z.coerce.number().int().positive(),
});

export const crearExpedienteForm = z.object({
  originUnitId: uuid,
  contractTypeId: uuid,
  planItemId: uuid,
  object: z.string().min(20, "Describa el objeto (mín. 20 caracteres)").max(4000),
  estimatedValue: z.coerce.number().positive(),
  estimatedDurationDays: z.coerce.number().int().positive(),
  unspscCodes: listaComas(z.string().regex(/^\d{8}$/, "Códigos UNSPSC de 8 dígitos")),
});
