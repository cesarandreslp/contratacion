"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { ZodError } from "zod";
import { withClm } from "@/lib/db/clm";
import { crearExpedienteForm } from "./configuracion-schema";
import {
  clmErrorCode,
  transitionCommand,
  transitionErrorFromCode,
  type GateFailure,
  type TransitionCommand,
  type TransitionError,
} from "./schema";

// Server Actions del Core Engine CLM. No verifican roles por su cuenta: todo corre
// con withClm (RLS + clm.transition), que es donde viven las reglas.
// Ver docs/04-spec-clm-core.md §4 y §11.

export interface ExpedienteResumen {
  id: string;
  number: number;
  object: string;
  state: string;
  estimated_value: number;
  origin_unit: string;
  updated_at: Date;
}

/** Expedientes que la sesión puede ver (la RLS filtra por tenant y árbol de dependencias). */
export async function listarExpedientes() {
  return withClm((tx) => tx.$queryRaw<ExpedienteResumen[]>`
    select d.id::text, d.number::int as number, d.object, d.state::text as state,
           d.estimated_value::float8 as estimated_value, u.name as origin_unit, d.updated_at
      from clm.dossiers d
      join clm.organizational_units u on u.id = d.origin_unit_id
     order by d.updated_at desc
     limit 200`);
}

export interface EventoDisponible {
  event: string;
  failures: GateFailure[];
}

/** Expediente + artefactos + observaciones + VoBo + checklist de compuertas de cada evento posible. */
export async function obtenerExpediente(id: string) {
  return withClm(async (tx) => {
    const [dossier] = await tx.$queryRaw<
      (ExpedienteResumen & { state_version: number; rigor_level: number; review_unit: string | null; seal_hash: string | null })[]
    >`
      select d.id::text, d.number::int as number, d.object, d.state::text as state, d.state_version,
             d.estimated_value::float8 as estimated_value, d.rigor_level::int as rigor_level,
             u.name as origin_unit, r.name as review_unit, d.seal_hash, d.updated_at
        from clm.dossiers d
        join clm.organizational_units u on u.id = d.origin_unit_id
        left join clm.organizational_units r on r.id = d.review_unit_id
       where d.id = ${id}::uuid`;
    if (!dossier) return null;

    const artifacts = await tx.$queryRaw<{ kind: string; title: string; label: string | null; sealed: boolean }[]>`
      select a.kind, a.title, v.label, a.sealed_at is not null as sealed
        from clm.artifacts a left join clm.artifact_versions v on v.id = a.current_version_id
       where a.dossier_id = ${id}::uuid
       order by a.stage, a.kind`;

    const observations = await tx.$queryRaw<
      { id: string; severity: string; status: string; category: string; body: string; artifact: string; block_id: string | null }[]
    >`
      select o.id::text, o.severity::text, o.status::text, o.category, o.body, a.kind as artifact, o.block_id
        from clm.observations o join clm.artifacts a on a.id = o.artifact_id
       where o.dossier_id = ${id}::uuid and o.status not in ('ACEPTADA','DESISTIDA')
       order by o.created_at`;

    const steps = await tx.$queryRaw<{ seq: number; role: string; status: string; decided_at: Date | null }[]>`
      select s.seq, s.role::text, s.status::text, s.decided_at
        from clm.approval_steps s join clm.dossiers d on d.id = s.dossier_id
       where s.dossier_id = ${id}::uuid and s.chain_no = d.approval_chain
       order by s.seq`;

    // Solo los eventos que esta sesión puede ejecutar (mismo criterio que app.authorize).
    const eventos = await tx.$queryRaw<{ event: string; failures: GateFailure[] }[]>`
      select t.event, clm.preview_gates(d.id, t.event) as failures
        from ref.fsm_transitions t
        join clm.dossiers d on d.id = ${id}::uuid and t.from_state = d.state
       where case t.actor_scope
               when 'ORIGIN'   then app.covers(t.actor_roles, d.origin_unit_id)
               when 'REVIEW'   then d.review_unit_id is not null and app.covers(t.actor_roles, d.review_unit_id)
               when 'ASSIGNED' then d.assigned_reviewer_id = auth.uid()
               when 'STEP'     then app.can_observe(d.id)
               else false
             end
       order by t.event`;

    return { dossier, artifacts, observations, steps, eventos: eventos as EventoDisponible[] };
  });
}

export type ResultadoTransicion = { ok: true; state: string } | { ok: false; error: TransitionError };

/** Dispara un evento de la FSM. Si una compuerta bloquea, devuelve el checklist completo. */
export async function dispararTransicion(input: TransitionCommand): Promise<ResultadoTransicion> {
  const cmd = transitionCommand.parse(input);
  try {
    const [row] = await withClm((tx) => tx.$queryRaw<{ state: string }[]>`
      select (clm.transition(${cmd.dossierId}::uuid, ${cmd.event}, ${cmd.expectedVersion}::int,
                             ${JSON.stringify(cmd.payload)}::jsonb)).state::text as state`);
    revalidatePath(`/expedientes/${cmd.dossierId}`);
    revalidatePath("/expedientes");
    return { ok: true, state: row.state };
  } catch (err) {
    const code = clmErrorCode(err);
    if (code !== "COMPUERTA_BLOQUEADA") return { ok: false, error: transitionErrorFromCode(code) };
    // Prisma no expone el DETAIL de Postgres: se recalcula el checklist (mismo estado, sin mutar).
    const [{ failures }] = await withClm((tx) => tx.$queryRaw<{ failures: GateFailure[] }[]>`
      select clm.preview_gates(${cmd.dossierId}::uuid, ${cmd.event}) as failures`);
    return { ok: false, error: transitionErrorFromCode(code, failures) };
  }
}

/** Opciones del formulario de nuevo expediente: solo unidades donde la sesión elabora. */
export async function opcionesNuevoExpediente() {
  return withClm(async (tx) => {
    const unidades = await tx.$queryRaw<{ id: string; name: string }[]>`
      select u.id::text, u.name from clm.organizational_units u
       where u.active and app.covers('{ELABORADOR,JEFE_AREA}', u.id) order by u.name`;
    const tipologias = await tx.$queryRaw<{ id: string; name: string }[]>`
      select id::text, name from clm.contract_types order by name`;
    const items = await tx.$queryRaw<{ id: string; label: string }[]>`
      select i.id::text, i.code || ' · ' || u.name || ' · ' || i.description as label
        from clm.procurement_plan_items i
        join clm.procurement_plans p on p.id = i.plan_id and p.status = 'APROBADO'
        join clm.organizational_units u on u.id = i.unit_id
       order by p.fiscal_year desc, i.code`;
    return { unidades, tipologias, items };
  });
}

/** Crea el expediente en BORRADOR con un artefacto vacío por cada uno que exige la tipología. */
export async function crearExpediente(
  _prev: { error: string } | null,
  fd: FormData,
): Promise<{ error: string }> {
  let id: string;
  try {
    const e = crearExpedienteForm.parse(Object.fromEntries(fd));
    id = await withClm(async (tx, tenantId) => {
      const [row] = await tx.$queryRaw<{ id: string }[]>`
        insert into clm.dossiers (tenant_id, origin_unit_id, contract_type_id, plan_item_id, object,
                                  estimated_value, estimated_duration_days, unspsc_codes)
        values (${tenantId}, ${e.originUnitId}::uuid, ${e.contractTypeId}::uuid, ${e.planItemId}::uuid, ${e.object},
                ${e.estimatedValue}, ${e.estimatedDurationDays}, ${e.unspscCodes})
        returning id::text`;
      await tx.$executeRaw`
        insert into clm.artifacts (tenant_id, dossier_id, kind, title)
        select ${tenantId}, ${row.id}::uuid, k, initcap(replace(k, '_', ' '))
          from clm.contract_types t, unnest(t.required_artifacts) k
         where t.id = ${e.contractTypeId}::uuid`;
      return row.id;
    });
  } catch (err) {
    if (err instanceof ZodError) return { error: err.issues[0]?.message ?? "Datos inválidos" };
    if (/row-level security|permission denied/i.test(String(err))) {
      return { error: "No tiene rol de elaborador en esa unidad." };
    }
    console.error(err);
    return { error: "No se pudo crear el expediente." };
  }
  revalidatePath("/expedientes");
  redirect(`/expedientes/${id}`);
}
