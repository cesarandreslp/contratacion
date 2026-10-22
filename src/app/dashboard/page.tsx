import { redirect } from "next/navigation";
import { requireSession } from "@/lib/auth/session";
import type { Role } from "@prisma/client";

// Panel inicial. Muestra accesos según el rol. El detalle de cada módulo se
// implementa en Fases 5-8 (contratos, cuentas de cobro, informes, revisión).

const ACCESOS: Record<Role, { href: string; label: string }[]> = {
  SUPERADMIN: [{ href: "/superadmin/tenants", label: "Gestionar entidades" }],
  ADMIN_TENANT: [
    { href: "/plantillas", label: "Plantillas" },
    { href: "/usuarios", label: "Usuarios" },
    { href: "/expedientes", label: "Expedientes precontractuales" },
  ],
  PERSONA_CONTRATACION: [
    { href: "/contratos", label: "Contratos" },
    { href: "/revisiones", label: "Revisiones pendientes" },
    { href: "/expedientes", label: "Expedientes precontractuales" },
  ],
  SUPERVISOR: [{ href: "/supervision", label: "Informe de supervisión (mes actual)" }],
  CONTRATISTA: [
    { href: "/cuentas-cobro/nueva", label: "Crear cuenta de cobro" },
    { href: "/cuentas-cobro", label: "Mis cuentas de cobro" },
  ],
};

export default async function DashboardPage() {
  let ctx;
  try {
    ctx = await requireSession();
  } catch {
    redirect("/login");
  }

  const accesos = ACCESOS[ctx.role] ?? [];

  return (
    <main>
      <h1>Panel</h1>
      <p style={{ color: "var(--muted)" }}>Rol: {ctx.role}</p>
      <ul>
        {accesos.map((a) => (
          <li key={a.href}>
            <a href={a.href}>{a.label}</a>
          </li>
        ))}
      </ul>
    </main>
  );
}
