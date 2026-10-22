# Plataforma de Gestión de Contratistas del Sector Público

Plataforma web **multi-tenant** para que entidades públicas colombianas gestionen el ciclo completo de los **contratos de prestación de servicios**: creación de contratos, informes de actividades asistidos por IA, informe de supervisión en 3ª persona, cuentas de cobro y actas (inicial/parcial/final).

**Open Source Solutions (OSS)** — superadmin de la plataforma.

> ⚠️ **Antes de trabajar:** lee [`docs/00-plan-bitacora.md`](docs/00-plan-bitacora.md). El protocolo obliga a revisar el plan al iniciar cada sesión y actualizar la bitácora tras cada actividad.

## Stack

Next.js (App Router) · Prisma · PostgreSQL · Vercel · Auth.js · Grok (xAI) · Vercel Blob/S3

## Estructura

```
docs/                 Especificación, reglas de negocio, RFC, bitácora
prisma/schema.prisma  Fuente de verdad del modelo de datos
src/lib/              db, auth, ai (grok), mail, storage, pdf
src/modules/          contratos, cuentas-cobro, informes, actas, revisiones
src/app/              Rutas (App Router)
```

## Puesta en marcha (dev)

```bash
npm install                  # incluye @vercel/blob y @react-pdf/renderer
cp .env.example .env.local   # completar variables
npm run db:generate
npm run db:migrate           # requiere PostgreSQL activo
npm run db:seed              # tenant demo + usuarios (pwd: Demo1234*)
npm run typecheck
npm run dev
```

## Documentación

| Doc | Contenido |
|-----|-----------|
| [00 — Plan y Bitácora](docs/00-plan-bitacora.md) | Fases, hitos, protocolo, bitácora de sesiones |
| [01 — Reglas de negocio CO](docs/01-reglas-negocio-co.md) | Parafiscales, seguridad social/PILA, vinculación |
| [02 — Prompts de Grok](docs/02-prompts-grok.md) | Prompts versionados de IA |
| [03 — RFC de arquitectura](docs/03-rfc-arquitectura.md) | Multi-tenancy, auth, storage, IA, PDF, mail |
| [04 — Spec Core Engine CLM](docs/04-spec-clm-core.md) | FSM, compuertas, RLS jerárquica, auditoría, IA (Supabase + pgvector) |
