import { z } from "zod";

// Contratos de API del Core Engine CLM (límite cliente ↔ Server Actions ↔ BD).
// Espejo de prisma/migrations/20261022120000_clm_core (schema `clm`). La BD es la
// fuente de verdad: Zod rechaza temprano y con buen mensaje, la BD vuelve a validar.
// Ver docs/04-spec-clm-core.md.

const uuid = z.string().uuid();
const money = z.coerce.number().positive().multipleOf(0.01);

// ---------------------------------------------------------------- enums (mismo orden que la BD)
export const appRole = z.enum([
  "ADMIN_ENTIDAD", "ELABORADOR", "JEFE_AREA", "PLANEACION", "PRESUPUESTO",
  "COORDINADOR_CONTRATACION", "REVISOR_JURIDICO", "JEFE_JURIDICA", "ORDENADOR_GASTO", "AUDITOR",
]);
export const dossierState = z.enum([
  "BORRADOR", "PENDIENTE_CDP", "EN_COLA_JURIDICA", "EN_REVISION_JURIDICA", "EN_SUBSANACION",
  "EN_CADENA_VOBO", "APROBADO", "EN_SELECCION", "ADJUDICADO", "PERFECCIONADO",
  "EJECUCION_HABILITADA", "DESISTIDO",
]);
export const obsSeverity = z.enum(["BLOQUEANTE", "SUSTANCIAL", "FORMA"]);
export type AppRole = z.infer<typeof appRole>;
export type DossierState = z.infer<typeof dossierState>;
export type ObsSeverity = z.infer<typeof obsSeverity>;

// ---------------------------------------------------------------- contenido por bloques + procedencia
export const citation = z.object({
  kind: z.enum(["public_chunk", "tenant_chunk", "price_benchmark", "public_document"]),
  id: z.string().min(1),
});
export type Citation = z.infer<typeof citation>;

export const provenance = z.discriminatedUnion("origin", [
  z.object({ origin: z.literal("HUMAN") }),
  z.object({ origin: z.literal("AI"), generation_id: uuid }),
  z.object({ origin: z.literal("AI_EDITED"), generation_id: uuid }),
  z.object({ origin: z.literal("TEMPLATE"), template_id: uuid, template_version: z.number().int() }),
]);

export const block = z
  .object({
    id: z.string().regex(/^[a-z0-9_-]{1,40}$/i), // estable entre versiones: el diff y las observaciones se anclan aquí
    type: z.enum(["heading", "paragraph", "list", "table", "value"]),
    section: z.string().optional(),               // clave normativa: necesidad, objeto, valor_estimado, riesgos...
    text: z.string(),
    value: z.number().optional(),
    provenance,
  })
  .refine((b) => b.type !== "value" || b.value !== undefined, { message: "Un bloque de valor requiere 'value'" });

export const artifactContent = z
  .object({ blocks: z.array(block) })
  .refine((c) => new Set(c.blocks.map((b) => b.id)).size === c.blocks.length, { message: "ids de bloque duplicados" });
export type ArtifactContent = z.infer<typeof artifactContent>;

// ---------------------------------------------------------------- creación y elaboración
export const guardarBorradorInput = z.object({ artifactId: uuid, content: artifactContent });
export const versionarInput = z.object({ artifactId: uuid, metadata: z.record(z.unknown()).default({}) });
export const ratificarAutoriaInput = z.object({
  versionId: uuid,
  acepto: z.literal(true, { errorMap: () => ({ message: "Debe ratificar la autoría para continuar" }) }),
});

// ---------------------------------------------------------------- revisión
export const crearObservacionInput = z.object({
  dossierId: uuid,
  artifactId: uuid,
  blockId: z.string().nullable(),
  severity: obsSeverity,
  category: z.enum(["JURIDICA", "TECNICA", "PRESUPUESTAL", "MERCADO", "FORMA"]),
  body: z.string().min(10),
});

export const respuestaObservacion = z
  .object({
    observationId: uuid,
    resolution: z.enum(["CORREGIDA", "NO_PROCEDE"]),
    justification: z.string().min(20, "Justifique la respuesta (mín. 20 caracteres)"),
    correctedVersionId: uuid.optional(),
  })
  .refine((r) => r.resolution !== "CORREGIDA" || r.correctedVersionId, {
    message: "Una corrección debe apuntar a la nueva versión",
    path: ["correctedVersionId"],
  });

/** Subsanación completa: respuestas punto a punto + reenvío, en una sola acción. */
export const subsanarYReenviarInput = z.object({
  dossierId: uuid,
  expectedVersion: z.number().int().nonnegative(),
  responses: z.array(respuestaObservacion).min(1),
});
export type SubsanarYReenviarInput = z.infer<typeof subsanarYReenviarInput>;

export const cerrarObservacionInput = z.object({
  observationId: uuid,
  status: z.enum(["ACEPTADA", "REABIERTA", "DESISTIDA"]),
});

// ---------------------------------------------------------------- transiciones de la FSM
const sinPayload = z.object({}).strict();
const base = { dossierId: uuid, expectedVersion: z.number().int().nonnegative() };
const ev = <E extends string, P extends z.ZodTypeAny>(event: E, payload: P) =>
  z.object({ ...base, event: z.literal(event), payload });

export const transitionCommand = z.discriminatedUnion("event", [
  ev("SOLICITAR_CDP", sinPayload),
  ev("EXPEDIR_CDP", z.object({ number: z.string().min(1), budget_line: z.string().min(1), amount: money })),
  ev("RECHAZAR_CDP", z.object({ reason: z.string().min(10) })),
  ev("ASIGNAR_REVISOR", z.object({ reviewer_id: uuid.optional() })),     // sin id = balanceo de carga
  ev("REASIGNAR_REVISOR", z.object({ reviewer_id: uuid.optional() })),
  ev("DEVOLVER", sinPayload),
  ev("REENVIAR", sinPayload),
  ev("APROBAR_REVISION", sinPayload),
  ev("VOBO", z.object({ comment: z.string().max(2000).optional() })),
  ev("RECHAZAR_VOBO", z.object({ comment: z.string().min(10) })),
  ev("INICIAR_SELECCION", sinPayload),
  ev("ADJUDICAR", z.object({
    contract_number: z.string().min(1),
    contractor_nit: z.string().regex(/^\d{6,10}(-\d)?$/),
    contractor_name: z.string().min(3),
    value: money,
    duration_days: z.number().int().positive().optional(),
  })),
  ev("ENSAMBLAR_CONTRATO", sinPayload),
  ev("EXPEDIR_RP", z.object({ number: z.string().min(1), budget_line: z.string().min(1), amount: money })),
  ev("REGISTRAR_GARANTIA", z.object({
    coverage: z.string().min(3), insurer: z.string().min(3), policy_number: z.string().min(1),
    insured_amount: money, valid_from: z.string().date(), valid_to: z.string().date(),
    document_path: z.string().optional(),
  })),
  ev("APROBAR_GARANTIA", z.object({ guarantee_id: uuid })),
  ev("RECHAZAR_GARANTIA", z.object({ guarantee_id: uuid })),
  ev("DESIGNAR_SUPERVISION", z.object({
    kind: z.enum(["SUPERVISION", "INTERVENTORIA"]),
    supervisor_user_id: uuid.optional(),
    external_name: z.string().optional(),
    designation_doc_path: z.string().optional(),
  }).refine((p) => p.supervisor_user_id || p.external_name, { message: "Indique supervisor o interventor" })),
  ev("HABILITAR_EJECUCION", z.object({ start_date: z.string().date().optional() })),
  ev("DESISTIR", z.object({ reason: z.string().min(10) })),
  // PERFECCIONAR no está aquí a propósito: solo lo dispara el webhook de firma (service_role).
]);
export type TransitionCommand = z.infer<typeof transitionCommand>;
export type TransitionEvent = TransitionCommand["event"];

// ---------------------------------------------------------------- errores de compuerta
export interface GateFailure {
  check: string;
  hard: boolean; // true = requisito legal de la FSM; false = regla de rigor del tenant
  message: string;
}

export type TransitionError =
  | { kind: "COMPUERTA_BLOQUEADA"; failures: GateFailure[] }
  | { kind: "CONFLICTO_DE_VERSION" }
  | { kind: "PERMISO"; code: string }
  | { kind: "OTRO"; code: string };

const CODIGOS_PERMISO = new Set([
  "ROL_NO_AUTORIZADO", "NO_ES_REVISOR_ASIGNADO", "NO_LE_CORRESPONDE_ESTE_VOBO",
  "CONFLICTO_DE_FUNCIONES", "SOLO_SISTEMA", "NO_AUTENTICADO",
]);

/**
 * Código de negocio de un error lanzado por PL/pgSQL (p. ej. COMPUERTA_BLOQUEADA).
 * Prisma lo entrega como "... Message: `CODIGO`"; null si no es uno nuestro
 * (los errores de RLS/privilegios de Postgres vienen en minúsculas).
 */
export function clmErrorCode(err: unknown): string | null {
  const msg = err instanceof Error ? err.message : String(err);
  const m = /Message: `([A-Z][A-Z_]+)`/.exec(msg) ?? /\b([A-Z]{3,}_[A-Z_]{3,})\b/.exec(msg);
  return m?.[1] ?? null;
}

/** Clasifica el código que lanzó clm.transition() (las fallas de compuerta se leen aparte). */
export function transitionErrorFromCode(code: string | null, failures: GateFailure[] = []): TransitionError {
  if (code === "COMPUERTA_BLOQUEADA") return { kind: "COMPUERTA_BLOQUEADA", failures };
  if (code === "CONFLICTO_DE_VERSION") return { kind: "CONFLICTO_DE_VERSION" };
  if (code && CODIGOS_PERMISO.has(code)) return { kind: "PERMISO", code };
  return { kind: "OTRO", code: code ?? "ERROR_DESCONOCIDO" };
}

// ---------------------------------------------------------------- co-piloto IA
export const aiAssistInput = z.object({
  dossierId: uuid,
  artifactId: uuid,
  blockId: z.string(),
  task: z.enum(["JUSTIFICACION", "OBJETO", "ALCANCE", "OBLIGACIONES", "MATRIZ_RIESGOS", "VALOR_ESTIMADO", "REVISION_NORMATIVA"]),
  instruction: z.string().max(2000).optional(),
});
export type AiAssistInput = z.infer<typeof aiAssistInput>;

/** Lo que devuelve el co-piloto. Para VALOR_ESTIMADO el número lo calcula SQL desde benchmarks, nunca el LLM. */
export interface AiSuggestion {
  generationId: string;
  text: string;
  value?: number;
  citations: Citation[];
}

export const decidirSugerenciaInput = z.object({
  generationId: uuid,
  decision: z.enum(["ACEPTADA", "EDITADA", "DESCARTADA"]),
});

// ---------------------------------------------------------------- firma (capa agnóstica)
export interface SignatureSigner {
  name: string;
  documentNumber: string;
  email: string;
  role: "CONTRATISTA" | "ORDENADOR_GASTO" | "TESTIGO";
}

/** Un adaptador por proveedor (Certicámara, GSE, DocuSign...). El core solo conoce esto. */
export interface SignatureProvider {
  readonly id: string;
  createEnvelope(input: { pdf: Uint8Array; pdfSha256: string; signers: SignatureSigner[]; callbackUrl: string }): Promise<{ externalId: string }>;
  /** Valida firma del webhook y normaliza el estado. Lanza si la firma HMAC no cuadra. */
  parseWebhook(req: { headers: Headers; rawBody: string }): Promise<{
    externalId: string;
    status: "FIRMADA" | "RECHAZADA" | "EXPIRADA";
    evidence: Record<string, unknown>;
    signedPdfSha256?: string;
  }>;
}

// ---------------------------------------------------------------- diff
export interface BlockDiffRow {
  block_id: string;
  change: "ADDED" | "REMOVED" | "MODIFIED" | "UNCHANGED";
  before: z.infer<typeof block> | null;
  after: z.infer<typeof block> | null;
}
