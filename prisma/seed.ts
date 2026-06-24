import { PrismaClient } from "@prisma/client";
import { hashPassword } from "../src/lib/auth/password";
import { PLANTILLAS_DEFAULT } from "../src/lib/plantillas/defaults";

// Seed de desarrollo: superadmin OSS, un tenant demo con usuarios por rol,
// plantillas por defecto, y un contrato de ejemplo asignado a un contratista.
// Ejecutar: npm run db:seed

const prisma = new PrismaClient();

async function main() {
  const pwd = hashPassword("Demo1234*");

  // --- Superadmin OSS (sin tenant) ---
  // No se puede usar upsert con la clave compuesta tenantId_email cuando
  // tenantId es null (limitación de Prisma), así que verificamos manualmente.
  const existingSuperadmin = await prisma.user.findFirst({
    where: { tenantId: null, email: "admin@oss.co" },
  });
  if (!existingSuperadmin) {
    await prisma.user.create({
      data: { email: "admin@oss.co", nombre: "OSS Admin", role: "SUPERADMIN", passwordHash: pwd },
    });
  }

  // --- Tenant demo ---
  const tenant = await prisma.tenant.upsert({
    where: { slug: "alcaldia-demo" },
    update: {},
    create: {
      nombre: "Alcaldía Demo",
      slug: "alcaldia-demo",
      nit: "900123456-7",
      config: {
        estandarRedaccion: { numeroParrafos: 5, lineasPorParrafo: 8 },
        operadoresPila: ["SOI", "COMPENSAR", "APORTES_EN_LINEA"],
        parafiscalesObligatorio: false,
      },
    },
  });

  // --- Usuarios del tenant por rol ---
  const [adminTenant, contratacion, supervisor, contratista] = await Promise.all([
    upsertUser(tenant.id, "admin@alcaldia-demo.co", "Admin Tenant", "ADMIN_TENANT", pwd),
    upsertUser(tenant.id, "contratacion@alcaldia-demo.co", "Persona Contratación", "PERSONA_CONTRATACION", pwd),
    upsertUser(tenant.id, "supervisor@alcaldia-demo.co", "Supervisor Demo", "SUPERVISOR", pwd),
    upsertUser(tenant.id, "contratista@alcaldia-demo.co", "Contratista Demo", "CONTRATISTA", pwd, "1098765432"),
  ]);

  // --- Plantillas por defecto ---
  for (const p of PLANTILLAS_DEFAULT) {
    await prisma.plantilla.create({
      data: { tenantId: tenant.id, tipo: p.tipo, nombre: p.nombre, contenido: p.contenido },
    });
  }

  // --- Contrato de ejemplo con obligaciones, asignado al contratista ---
  const contrato = await prisma.contrato.create({
    data: {
      tenantId: tenant.id,
      creadorId: contratacion.id,
      objeto: "Prestación de servicios profesionales de apoyo a la gestión administrativa.",
      vigenciaInicio: new Date("2026-07-01"),
      vigenciaFin: new Date("2026-12-31"),
      valorTotal: "30000000",
      valorCuota: "5000000",
      numeroCuotas: 6,
      tipoVinculacion: "PROFESIONAL",
      nivelRiesgoArl: 1,
      obligaciones: {
        create: [
          { texto: "Apoyar la elaboración de informes de gestión del área.", orden: 1 },
          { texto: "Realizar seguimiento a los procesos contractuales asignados.", orden: 2 },
          { texto: "Atender los requerimientos de las dependencias.", orden: 3 },
        ],
      },
    },
  });

  await prisma.contratoContratista.create({
    data: {
      contratoId: contrato.id,
      contratistaId: contratista.id,
      supervisorId: supervisor.id,
      numeroContrato: "CPS-2026-001",
    },
  });

  console.log("Seed completado. Tenant:", tenant.slug, "| usuarios:", {
    adminTenant: adminTenant.email,
    contratacion: contratacion.email,
    supervisor: supervisor.email,
    contratista: contratista.email,
  });
  console.log("Contraseña demo para todos: Demo1234*");
}

function upsertUser(
  tenantId: string,
  email: string,
  nombre: string,
  role: "ADMIN_TENANT" | "PERSONA_CONTRATACION" | "SUPERVISOR" | "CONTRATISTA",
  passwordHash: string,
  cedula?: string,
) {
  return prisma.user.upsert({
    where: { tenantId_email: { tenantId, email } },
    update: {},
    create: { tenantId, email, nombre, role, passwordHash, cedula },
  });
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
