"use server";

import { revalidatePath } from "next/cache";
import { ZodError } from "zod";
import { requireTenant } from "@/lib/auth/session";
import { withClm, withClmOwner, type ClmTx } from "@/lib/db/clm";
import { clmErrorCode } from "./schema";
import {
  activarClmInput,
  agregarItemPaaInput,
  crearDelegacionInput,
  crearPlanInput,
  crearTipologiaInput,
  crearUnidadInput,
  otorgarRolInput,
} from "./configuracion-schema";

// Configuración del CLM por entidad: activación, organigrama, roles con alcance,
// delegación, tipologías y PAA. Salvo la activación, todo corre con RLS: solo
// ADMIN_ENTIDAD (alcance TENANT) configura y solo PLANEACION toca el PAA.
// Ver docs/04-spec-clm-core.md §2.

export type ResultadoForm = { ok: true } | { ok: false; error: string };

function mensaje(err: unknown): string {
  if (err instanceof ZodError) return err.issues[0]?.message ?? "Datos inválidos";
  const msg = err instanceof Error ? err.message : String(err);
  if (/row-level security|permission denied/i.test(msg)) return "No tiene el rol del CLM para esta acción.";
  if (/unique|duplicate key|23505/i.test(msg)) return "Ya existe un registro con esos datos.";
  const code = clmErrorCode(err);
  if (code) return code.replaceAll("_", " ");
  console.error(err);
  return "No se pudo guardar.";
}

async function guardar(paso: () => Promise<unknown>): Promise<ResultadoForm> {
  try {
    await paso();
  } catch (err) {
    return { ok: false, error: mensaje(err) };
  }
  revalidatePath("/expedientes/configuracion");
  return { ok: true };
}

const datos = (fd: FormData) => Object.fromEntries(fd);

export interface Unidad {
  id: string;
  parent_id: string | null;
  kind: string;
  code: string;
  name: string;
  depth: number;
}

/** Todo lo que pinta la página de configuración. */
export async function estadoClm() {
  const { ctx, db } = await requireTenant();
  const usuarios = await db.user.findMany({
    where: { activo: true },
    select: { id: true, nombre: true, email: true },
    orderBy: { nombre: "asc" },
  });
  const clm = await withClm(async (tx: ClmTx) => {
    const [{ activo }] = await tx.$queryRaw<{ activo: boolean }[]>`select exists (select 1 from clm.tenants) as activo`;
    const unidades = await tx.$queryRaw<Unidad[]>`
      select id::text, parent_id::text, kind::text, code, name, cardinality(path)::int as depth
        from clm.organizational_units order by path`;
    const membresias = await tx.$queryRaw<{ id: string; user_id: string; role: string; scope: string; unit: string }[]>`
      select m.id::text, m.user_id, m.role::text, m.scope::text, u.name as unit
        from clm.user_memberships m join clm.organizational_units u on u.id = m.unit_id
       where m.valid_to is null or m.valid_to >= current_date
       order by u.name, m.role`;
    const delegaciones = await tx.$queryRaw<{ origen: string; revisa: string; tipologia: string | null; min_amount: number }[]>`
      select o.name as origen, r.name as revisa, t.code as tipologia, d.min_amount::float8 as min_amount
        from clm.review_delegations d
        join clm.organizational_units o on o.id = d.origin_unit_id
        join clm.organizational_units r on r.id = d.review_unit_id
        left join clm.contract_types t on t.id = d.contract_type_id
       order by o.name`;
    const tipologias = await tx.$queryRaw<
      { id: string; code: string; name: string; requires_selection: boolean; requires_guarantees: boolean; required_artifacts: string[] }[]
    >`select id::text, code, name, requires_selection, requires_guarantees, required_artifacts from clm.contract_types order by code`;
    const planes = await tx.$queryRaw<{ id: string; fiscal_year: number; version: number; status: string }[]>`
      select id::text, fiscal_year::int, version, status from clm.procurement_plans order by fiscal_year desc, version desc`;
    const items = await tx.$queryRaw<
      { id: string; plan_id: string; code: string; description: string; estimated_value: number; unit: string; unspsc: string[] }[]
    >`
      select i.id::text, i.plan_id::text, i.code, i.description, i.estimated_value::float8 as estimated_value,
             u.name as unit, i.unspsc_codes as unspsc
        from clm.procurement_plan_items i join clm.organizational_units u on u.id = i.unit_id
       order by i.code`;
    return { activo, unidades, membresias, delegaciones, tipologias, planes, items };
  });
  return { esAdminTenant: ctx.role === "ADMIN_TENANT", usuarios, ...clm };
}

/** Arranque: crea la extensión CLM de la entidad, la jurídica central y hace al admin ADMIN_ENTIDAD. */
export async function activarClm(fd: FormData): Promise<ResultadoForm> {
  return guardar(async () => {
    await requireTenant("tenant:configure");
    const input = activarClmInput.parse(datos(fd));
    await withClmOwner(async (tx, tenantId, userId) => {
      const n = await tx.$executeRaw`
        insert into clm.tenants (id, territorial_order) values (${tenantId}, ${input.territorialOrder})
        on conflict (id) do nothing`;
      if (n === 0) throw new Error("CLM_YA_ACTIVO");
      await tx.$executeRaw`insert into clm.users (id, tenant_id) values (${userId}, ${tenantId}) on conflict (id) do nothing`;
      const [{ id }] = await tx.$queryRaw<{ id: string }[]>`
        insert into clm.organizational_units (tenant_id, kind, code, name)
        values (${tenantId}, 'JURIDICA_CENTRAL', 'JURIDICA', ${input.juridicaNombre}) returning id::text`;
      await tx.$executeRaw`
        insert into clm.user_memberships (tenant_id, user_id, unit_id, role, scope)
        values (${tenantId}, ${userId}, ${id}::uuid, 'ADMIN_ENTIDAD', 'TENANT')`;
      await tx.$executeRaw`select app.bootstrap_tenant(${tenantId})`; // reglas por defecto (devuelve void)
    });
  });
}

export async function crearUnidad(fd: FormData): Promise<ResultadoForm> {
  return guardar(async () => {
    const u = crearUnidadInput.parse(datos(fd));
    await withClm((tx, tenantId) => tx.$executeRaw`
      insert into clm.organizational_units (tenant_id, parent_id, kind, code, name)
      values (${tenantId}, ${u.parentId ?? null}::uuid, ${u.kind}::clm.unit_kind, ${u.code}, ${u.name})`);
  });
}

/** Da un rol con alcance. El usuario entra a clm.users si no estaba (en la misma transacción, con RLS para el rol). */
export async function otorgarRol(fd: FormData): Promise<ResultadoForm> {
  return guardar(async () => {
    const r = otorgarRolInput.parse(datos(fd));
    const { db } = await requireTenant();
    const usuario = await db.user.findFirst({ where: { id: r.userId, activo: true }, select: { id: true } });
    if (!usuario) throw new Error("USUARIO_NO_ENCONTRADO");
    await withClmOwner(async (tx, tenantId) => {
      await tx.$executeRaw`insert into clm.users (id, tenant_id) values (${r.userId}, ${tenantId}) on conflict (id) do nothing`;
      await tx.$executeRawUnsafe("set local role authenticated");
      await tx.$executeRaw`
        insert into clm.user_memberships (tenant_id, user_id, unit_id, role, scope)
        values (${tenantId}, ${r.userId}, ${r.unitId}::uuid, ${r.role}::clm.app_role, ${r.scope}::clm.role_scope)
        on conflict (tenant_id, user_id, unit_id, role)
        do update set scope = excluded.scope, valid_from = current_date, valid_to = null`;
    });
  });
}

/** Revoca dejando vigencia hasta ayer: la membresía queda en la bitácora, no se borra. */
export async function revocarRol(fd: FormData): Promise<ResultadoForm> {
  return guardar(async () => {
    const id = String(fd.get("id") ?? "");
    const n = await withClm((tx) => tx.$executeRaw`
      update clm.user_memberships set valid_to = current_date - 1 where id = ${id}::uuid`);
    if (n === 0) throw new Error("permission denied");
  });
}

export async function crearDelegacion(fd: FormData): Promise<ResultadoForm> {
  return guardar(async () => {
    const d = crearDelegacionInput.parse(datos(fd));
    await withClm((tx, tenantId) => tx.$executeRaw`
      insert into clm.review_delegations (tenant_id, origin_unit_id, review_unit_id, contract_type_id, min_amount)
      values (${tenantId}, ${d.originUnitId}::uuid, ${d.reviewUnitId}::uuid, ${d.contractTypeId ?? null}::uuid, ${d.minAmount})`);
  });
}

export async function crearTipologia(fd: FormData): Promise<ResultadoForm> {
  return guardar(async () => {
    const t = crearTipologiaInput.parse(datos(fd));
    await withClm((tx, tenantId) => tx.$executeRaw`
      insert into clm.contract_types (tenant_id, code, name, requires_selection, requires_guarantees, required_artifacts)
      values (${tenantId}, ${t.code}, ${t.name}, ${t.requiresSelection}, ${t.requiresGuarantees}, ${t.requiredArtifacts})`);
  });
}

export async function crearPlan(fd: FormData): Promise<ResultadoForm> {
  return guardar(async () => {
    const p = crearPlanInput.parse(datos(fd));
    await withClm((tx, tenantId) => tx.$executeRaw`
      insert into clm.procurement_plans (tenant_id, fiscal_year, version)
      values (${tenantId}, ${p.fiscalYear},
              (select coalesce(max(version), 0) + 1 from clm.procurement_plans where fiscal_year = ${p.fiscalYear}))`);
  });
}

export async function agregarItemPaa(fd: FormData): Promise<ResultadoForm> {
  return guardar(async () => {
    const i = agregarItemPaaInput.parse(datos(fd));
    await withClm((tx, tenantId) => tx.$executeRaw`
      insert into clm.procurement_plan_items (tenant_id, plan_id, unit_id, code, description, unspsc_codes,
                                              estimated_value, modality, expected_start, duration_days)
      values (${tenantId}, ${i.planId}::uuid, ${i.unitId}::uuid, ${i.code}, ${i.description}, ${i.unspscCodes},
              ${i.estimatedValue}, ${i.modality}, ${i.expectedStart}::date, ${i.durationDays})`);
  });
}

/** Aprobar congela el plan: sus ítems ya no se editan (la RLS solo deja tocar planes en BORRADOR). */
export async function aprobarPlan(fd: FormData): Promise<ResultadoForm> {
  return guardar(async () => {
    const id = String(fd.get("id") ?? "");
    const n = await withClm((tx) => tx.$executeRaw`
      update clm.procurement_plans set status = 'APROBADO', approved_at = now()
       where id = ${id}::uuid and status = 'BORRADOR'`);
    if (n === 0) throw new Error("permission denied");
  });
}
