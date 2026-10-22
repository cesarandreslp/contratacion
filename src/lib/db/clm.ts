import type { Prisma } from "@prisma/client";
import { prisma } from "./prisma";
import { requireTenant } from "@/lib/auth/session";

// Acceso al Core Engine CLM (schema `clm`, migración 20261022120000_clm_core).
// A diferencia del wrapper tenant-scoped, aquí la autoridad es la base de datos:
// cada transacción fija los claims de la sesión y baja al rol `authenticated`,
// así que la RLS de clm decide qué se ve y qué se puede mutar.
// Ver docs/04-spec-clm-core.md §3 y §11.

export type ClmTx = Prisma.TransactionClient;

/** Ejecuta `fn` como el usuario de la sesión (RLS activa). Todo dentro de una transacción. */
export async function withClm<T>(fn: (tx: ClmTx) => Promise<T>): Promise<T> {
  const { ctx } = await requireTenant();
  const claims = JSON.stringify({
    sub: ctx.userId,
    role: "authenticated",
    app_metadata: { tenant_id: ctx.tenantId },
  });
  return prisma.$transaction(async (tx) => {
    await tx.$queryRaw`select set_config('request.jwt.claims', ${claims}, true)`;
    await tx.$executeRawUnsafe("set local role authenticated");
    return fn(tx);
  });
}
