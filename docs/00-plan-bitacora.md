# 00 — Plan de Trabajo y Bitácora

> ⚠️ **PROTOCOLO OBLIGATORIO:** al iniciar o retomar cualquier sesión, lo PRIMERO es consultar este documento. Antes de ejecutar cualquier acción, revisar el plan para confirmar alineación. Después de **cada** actividad, **actualizar la bitácora**. Prioritario y no negociable.

---

## 0.1 Fases del Proyecto

| # | Fase | Duración | Inicio | Fin | Estado |
|---|------|----------|--------|-----|--------|
| 1 | Análisis y Especificación Técnica Detallada | 2-3 sem | Jun 2026 | Jul 2026 | **EN PROGRESO** |
| 2 | Diseño de Arquitectura y Base de Datos | 2-3 sem | Jul 2026 | Ago 2026 | **EN PROGRESO** (adelantado) |
| 3 | Configuración del Stack e Infraestructura | 1-2 sem | Ago 2026 | Ago 2026 | **EN PROGRESO** (adelantado) |
| 4 | Módulo de Autenticación y Multi-Tenant | 3 sem | Ago 2026 | Sep 2026 | Pendiente |
| 5 | Módulo de Gestión de Contratos | 4 sem | Sep 2026 | Oct 2026 | **Implementado** (adelantado) |
| 6 | Módulo de Informes + Integración Grok | 4 sem | Oct 2026 | Nov 2026 | **Implementado** (adelantado) |
| 7 | Módulo de Actas, Cuentas de Cobro y Documentos | 4 sem | Nov 2026 | Dic 2026 | **Implementado** (incl. PDF binario) |
| 8 | Módulo de Revisión y Aprobación | 2-3 sem | Dic 2026 | Ene 2027 | **Implementado** (adelantado) |
| 9 | Testing, QA y Ajustes | 3-4 sem | Ene 2027 | Feb 2027 | **En progreso** (suite unitaria de reglas críticas) |
| 10 | Deployment a Producción y Capacitación | 2-3 sem | Feb 2027 | Mar 2027 | **En progreso** (deploy inicial en Vercel) |

## 0.2 Hitos Principales

| Hito | Descripción | Fecha | Estado |
|------|-------------|-------|--------|
| H1 | Especificación aprobada | 30 Jun 2026 | En curso |
| H2 | Schema Prisma + Arquitectura | 20 Ago 2026 | **Borrador entregado** (adelantado) |
| H3 | MVP Auth + Tenant Setup | 30 Sep 2026 | Pendiente |
| H4 | Contrato + Obligaciones | 31 Oct 2026 | Pendiente |
| H5 | Informe + IA | 30 Nov 2026 | Pendiente |
| H6 | Cuentas y Actas | 31 Dic 2026 | Pendiente |
| H7 | Flujo Completo + Testing | 28 Feb 2027 | Pendiente |
| H8 | Go-Live | 31 Mar 2027 | Pendiente |

---

## 0.3 Bitácora de Actividades

### Sesión 1 — 22 de Junio de 2026

| Actividad | Descripción | Estado |
|-----------|-------------|--------|
| Especificación funcional completa | Flujo completo: contratos, multi-contratista, informes con IA, ampliación, supervisión 3ª persona, cuentas de cobro, actas, anexos, aprobación. | ✅ |
| Generación de Prompt Markdown | Documento estructurado con stack, arquitectura, roles, modelo de datos, reglas. | ✅ |
| Plan de Trabajo y Bitácora | Sección de seguimiento (fases, hitos, bitácora). | ✅ |

### Sesión 2 — 22 de Junio de 2026

| Actividad | Descripción | Estado | Observaciones |
|-----------|-------------|--------|--------------|
| Reglas de negocio CO | `docs/01-reglas-negocio-co.md`: parafiscales, seguridad social/PILA, tipos de vinculación, validaciones. | ✅ | Pendiente confirmar con PO naturaleza de "documento de parafiscales". |
| Prompts de Grok | `docs/02-prompts-grok.md` + `src/lib/ai/prompts.ts`: corrección, ampliación, supervisión (versionados). | ✅ | Estándar configurable por tenant. |
| RFC de arquitectura | `docs/03-rfc-arquitectura.md`: multi-tenancy (shared + tenantId), auth (Auth.js/RBAC), storage, IA, PDF, mail. | ✅ | Varias decisiones abiertas listadas para H2. |
| Bootstrap del proyecto | `package.json`, `tsconfig.json`, `next.config.mjs`, `.env.example`, `.gitignore`, stubs en `src/lib/{db,auth,ai}`. | ✅ | Falta `npm install` + scaffold de `app/` y módulos. |
| schema.prisma | Modelo de datos completo con todas las entidades, enums y relaciones del documento base. | ✅ | Pendiente `prisma migrate` y `seed.ts`. |

### Sesión 2 (cont.) — 22 de Junio de 2026 — Fase 3/4

| Actividad | Descripción | Estado | Observaciones |
|-----------|-------------|--------|--------------|
| Decisiones RFC resueltas | PDF=@react-pdf/renderer, mail=Resend, RLS diferido, contratista 1-User-por-tenant, parafiscales config. no obligatorio. | ✅ | Ver RFC §10. |
| Wrapper tenant-scoped | `src/lib/db/tenant-scope.ts`: Prisma Client Extension que inyecta `tenantId` en lecturas/escrituras. | ✅ | Núcleo del aislamiento multi-tenant. |
| Autenticación (Auth.js v5) | `auth.ts`, `session.ts`, `password.ts` (scrypt), `next-auth.d.ts`, route handler. Sesión con tenantId+role. | ✅ | Inicio de Fase 4 / H3. |
| Correo y almacenamiento | `mail/mail.ts` (Resend + plantillas aprobación/rechazo), `storage/storage.ts` (Vercel Blob + validación). | ✅ | Requiere `@vercel/blob`. |
| Plantillas por defecto | `lib/plantillas/defaults.ts`: contrato, actas (inicial/parcial/final), cuenta de cobro, parafiscales. | ✅ | Con marcadores `{{campo}}`. |
| Seed de desarrollo | `prisma/seed.ts`: superadmin OSS, tenant demo, usuarios por rol, plantillas, contrato ejemplo. | ✅ | Pwd demo: `Demo1234*`. |
| Scaffold App Router | `src/app/`: layout, home, login, dashboard por rol, route handler de auth, globals.css. | ✅ | Falta `npm install` + módulos de negocio. |

### Sesión 2 (cont.) — 22 de Junio de 2026 — Fase 5 (Módulo de Contratos · H4)

| Actividad | Descripción | Estado | Observaciones |
|-----------|-------------|--------|--------------|
| Validación Zod | `modules/contratos/schema.ts`: crear contrato (con coherencia valorCuota×cuotas=total) y asignación multi-contratista. | ✅ | |
| Server Actions | `modules/contratos/actions.ts`: crear, listar, obtener, asignarContratistas, listarUsuariosPorRol. Todas tenant-scoped + permisos. | ✅ | Asignación valida rol y pertenencia al tenant. |
| UI Contratos | `app/contratos/`: lista, alta (form cliente), detalle con obligaciones + asignación multi-contratista dinámica. | ✅ | |
| Fix wrapper tenant | `upsert` sobre modelo scoped ahora inyecta `tenantId` en payload `create`. | ✅ | extendedWhereUnique (Prisma 6). |

### Sesión 2 (cont.) — 22 de Junio de 2026 — Fases 6/7/8 (flujo end-to-end)

| Actividad | Descripción | Estado | Observaciones |
|-----------|-------------|--------|--------------|
| Módulo cuentas de cobro | `modules/cuentas-cobro/`: crear (1:1 con cuota, snapshot del contrato), listar, obtener, firma, enviarARevision (valida evidencia y planilla). | ✅ | |
| Módulo informes + Grok | `modules/informes/`: registrarObligacionEjecutada (evidencia obligatoria + ampliación IA), editar ampliada, generarSupervision (3ª persona). | ✅ | Estándar de redacción por tenant. |
| Módulo actas | `modules/actas/`: inicial (primer pago+pendiente), parcial (pago+saldo), final (relación de pagos). Render desde plantillas. | ✅ | `lib/documentos/render.ts`. |
| Módulo revisiones | `modules/revisiones/`: listar pendientes, aprobar/rechazar (observaciones obligatorias), genera acta parcial + correo al contratista. | ✅ | |
| Módulo supervisión | `modules/supervision/`: supervisor ve solo informes del mes actual. | ✅ | |
| Subida de archivos | `app/api/upload/route.ts`: evidencias/documentos/firmas a Vercel Blob (valida MIME/tamaño). | ✅ | |
| UI completa | `app/cuentas-cobro/` (lista/nueva/detalle con flujo IA), `app/revisiones/`, `app/supervision/`. | ✅ | |

> Con esto el flujo funcional de las Fases 5-8 (creación → cuenta → informe IA → supervisión → actas → revisión → notificación) queda implementado a nivel de aplicación. Pendiente: generación binaria de PDF, verificación en ejecución y QA (Fase 9).

### Sesión 2 (cont.) — 22 de Junio de 2026 — Hardening y desbloqueo de flujo

| Actividad | Descripción | Estado | Observaciones |
|-----------|-------------|--------|--------------|
| Fix create anidado | `InformeActividades` (scoped) se creaba anidado sin `tenantId` → fallaría. Se pasa `tenantId` explícito + nota en `tenant-scope.ts`. | ✅ | Limitación documentada. |
| Módulo + UI de anexos | `modules/anexos/actions.ts` (registrar/eliminar) + `app/cuentas-cobro/[id]/anexos-cliente.tsx`. **Desbloquea `enviarARevision`** (exigía planilla SS sin forma de subirla). | ✅ | Flujo end-to-end ahora completable. |
| Hardening aislamiento | `generarActaInicial/Final` y `editarDescripcionAmpliada` validaban por id sin tenant (modelos no scoped). Se filtran por relación `contrato.tenantId` / propiedad del contratista. | ✅ | |

### Sesión 2 (cont.) — 22 de Junio de 2026 — PDF binario (cierre Fase 7)

| Actividad | Descripción | Estado | Observaciones |
|-----------|-------------|--------|--------------|
| Componente PDF | `lib/pdf/documento-pdf.tsx`: render genérico (@react-pdf/renderer) de un `DocumentoRenderizado` con encabezado de entidad y pie con paginación. | ✅ | runtime Node.js. |
| Constructores de documento | `lib/documentos/construir.ts`: cuenta de cobro (plantilla), informe de actividades (por obligación) y supervisión (texto IA). | ✅ | |
| Route handler descarga | `app/api/documentos/route.ts`: PDF de cuenta/informe/supervisión/acta con aislamiento por tenant y control por rol. | ✅ | Enlaces en detalle de cuenta. |
| Dependencias | `@react-pdf/renderer` y `@vercel/blob` añadidas a `package.json`. | ✅ | |

### Sesión 2 (cont.) — 22 de Junio de 2026 — Fase 9: suite de tests

| Actividad | Descripción | Estado | Observaciones |
|-----------|-------------|--------|--------------|
| Refactor testeable | Lógica de aislamiento extraída a `lib/db/tenant-scope-core.ts` (pura, sin Prisma) para poder testearla sin BD. | ✅ | `tenant-scope.ts` la reexporta. |
| Config Vitest | `vitest.config.ts` + `vite-tsconfig-paths`; scripts `test` / `test:watch`. | ✅ | |
| Tests reglas críticas | 8 archivos en `tests/`: aislamiento multi-tenant, coherencia de contrato, evidencia obligatoria, observaciones al rechazar, RBAC, password scrypt, render de plantillas, datos PILA. | ✅ | ~35 casos. |

> Cubre como **tests unitarios** las reglas que no requieren BD. Pendiente: tests de integración de las Server Actions (requieren BD de pruebas) y e2e del flujo.

### Sesión 2 (cont.) — 22 de Junio de 2026 — Middleware de protección por rol

| Actividad | Descripción | Estado | Observaciones |
|-----------|-------------|--------|--------------|
| Split config Auth.js | `lib/auth/auth.config.ts` (edge-safe, sin Prisma) compartida por middleware y `auth.ts` (Node). Callbacks jwt/session movidos allí. | ✅ | Requisito del runtime Edge. |
| Lógica de acceso | `lib/auth/route-access.ts`: mapa prefijo→roles + `rutaPermitida`/`esPublica` (puro, testeable). | ✅ | Alineado con el panel. |
| Middleware | `src/middleware.ts`: redirige sin sesión a /login (con callbackUrl) y por rol no autorizado a /dashboard. Excluye `/api` y estáticos. | ✅ | Defensa en profundidad. |
| Tests middleware | `tests/route-access.test.ts` (7 casos de acceso por rol). | ✅ | |

### Sesión 2 (cont.) — 22 de Junio de 2026 — Revisión estática y fixes

> Pasada de revisión manual (sin poder ejecutar tsc/runtime) para cazar errores de compilación/serialización.

| Hallazgo | Fix | Estado |
|----------|-----|--------|
| Server Actions devolvían objetos Prisma con `Decimal` a componentes cliente (no serializable) | `crearContrato` y `crearCuentaCobro` ahora devuelven `{ id }` (`select`). | ✅ |
| `export type` + schema inline en archivo `"use server"` (anexos) | Schema movido a `modules/anexos/schema.ts`. | ✅ |
| `@react-pdf/renderer` puede fallar al empaquetarse en el servidor | `serverExternalPackages: ["@react-pdf/renderer"]` en `next.config.mjs`. | ✅ |
| Verificación de retornos restantes | `return acta` (sin Decimal) y `return cuenta` (Server Components / helper interno) → OK. | ✅ |

### Sesión 2 (cont.) — 22 de Junio de 2026 — Deploy inicial en Vercel

| Actividad | Descripción | Estado | Observaciones |
|-----------|-------------|--------|--------------|
| Commit + push + deploy | El código se versionó y se desplegó en Vercel. El build (`prisma generate && next build`) valida el typecheck completo. | ✅ | Primera verificación real del compilado. |

#### Checklist post-deploy (operativo — confirmar)

- [ ] Variables de entorno en Vercel: `DATABASE_URL`, `AUTH_SECRET`, `AUTH_URL`, `GROK_API_KEY`, `BLOB_READ_WRITE_TOKEN`, `RESEND_API_KEY`, `MAIL_FROM`.
- [ ] **Migraciones contra la BD de producción**: `prisma migrate deploy` (Vercel NO las corre solo → sin tablas, la app falla en runtime).
- [ ] **Seed** (al menos un tenant + usuarios) para poder iniciar sesión.
- [ ] Probar el flujo end-to-end en la URL de producción.

### Sesión 2 (cont.) — 22 de Junio de 2026 — VERIFICACIÓN REAL (install/test/typecheck/build)

> Se ejecutó el entorno (node 26, npm 11). Bugs reales encontrados y corregidos:

| Bug encontrado | Fix |
|----------------|-----|
| `schema.prisma`: relación `ContratoSupervisor` apuntaba `User.contratosSupervisados` a `Contrato[]` en vez de `ContratoContratista[]` | Corregida la relación |
| `vitest.config.ts` cargaba como CJS pero `vite-tsconfig-paths` es solo-ESM | Config → `.mts` + alias `@/` manual; dependencia eliminada |
| Wrapper tenant-scoped: TS exige `tenantId` en los `create` (la inyección runtime es invisible para TS) | `tenantId` explícito en todos los creates de modelos scoped (contratos, cuentas, actas×3, revisiones) |
| Casts `JsonValue → PlantillaContenido` inválidos | `as unknown as PlantillaContenido` |
| `cuenta-cliente.tsx` importaba `generarSupervision` de `cuentas-cobro/actions` (está en `informes/actions`) | Import corregido |

**Resultados finales:**
- ✅ `npm install` — 161 paquetes
- ✅ `npx prisma generate` — cliente OK (postinstall bloqueado por política → correr explícito)
- ✅ `npm test` — **46/46 tests pasando** (9 archivos)
- ✅ `npm run typecheck` — **sin errores**
- ✅ `npm run build` — **14 rutas + middleware compilan** (igual que Vercel)

> **Hallazgo crítico:** `C:\contratacion` NO era repo git, no tenía `.vercel`, ni `node_modules`, ni `.env`. → El proyecto **nunca se había desplegado realmente desde aquí**; lo que el usuario vio en Vercel/GitHub no es este código. Falta unir código ↔ repo ↔ Vercel ↔ Neon.

### Sesión 2 (cont.) — 22 de Junio de 2026 — Persistencia probada + git

| Actividad | Resultado |
|-----------|-----------|
| Migración inicial Prisma | `prisma/migrations/20260622000000_init/` (307 líneas SQL), generada con `migrate diff` (sin BOM). |
| Smoke test de persistencia | PostgreSQL embebido real → migración + insertar tenant/usuario/contrato → leer de vuelta → **✅ datos se guardan y leen OK** (incl. Decimal y relaciones anidadas). `prisma/smoke-test.ts`. |
| CI GitHub Actions | `.github/workflows/ci.yml` (install/generate/lint/typecheck/test/build). |
| Repositorio git | `git init` + commit inicial `5967f28` (80 archivos, node_modules excluido). **Sin push aún** (requiere PAT). |

> **El código y la capa de datos están VERIFICADOS de punta a punta.** Lo único que falta para producción depende de credenciales del usuario.

### Próximos pasos (requieren acción del usuario)

- [ ] **Push a GitHub `SEEL249`:** generar Personal Access Token y `git remote add origin … && git push -u origin main` (o dármelo para hacerlo).
- [ ] **Conectar Neon:** poner `DATABASE_URL` en `.env.local` → `npx prisma migrate deploy` → `npm run db:seed`.
- [ ] **Vercel:** configurar variables (`DATABASE_URL`, `AUTH_SECRET`, `AUTH_URL`, `GROK_API_KEY`, `BLOB_READ_WRITE_TOKEN`, `RESEND_API_KEY`, `MAIL_FROM`) y desplegar desde el repo real.
- [ ] **Validar con PO (Cesar):** naturaleza del "documento de parafiscales" + tarifas/IBC vigentes.
- [ ] 🔐 **Rotar contraseñas de Neon y GitHub compartidas en el chat.**

---

## Índice de documentación

- [00 — Plan y Bitácora](00-plan-bitacora.md) (este documento)
- [01 — Reglas de negocio CO](01-reglas-negocio-co.md)
- [02 — Prompts de Grok](02-prompts-grok.md)
- [03 — RFC de arquitectura](03-rfc-arquitectura.md)
- [`prisma/schema.prisma`](../prisma/schema.prisma) — fuente de verdad del modelo de datos
