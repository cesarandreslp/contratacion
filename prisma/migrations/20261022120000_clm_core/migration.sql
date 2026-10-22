-- =============================================================================
-- CLM Core Engine sobre Neon (migración Prisma).
-- Misma lógica que supabase/migrations/20261022000000_clm_core.sql, adaptada:
--   * Todo vive en el schema `clm`: Prisma solo gestiona `public`, así que
--     `prisma migrate` no ve estas tablas como deriva.
--   * clm.tenants / clm.users extienden public."Tenant" / public."User" (ids cuid → text).
--   * auth.jwt() / auth.uid() leen `request.jwt.claims`, que la app fija por
--     transacción junto con SET LOCAL ROLE authenticated (src/lib/db/clm.ts).
--   * Sin service_role: las tareas de sistema (webhook de firma, ingesta) corren
--     con el rol dueño de las tablas, que no pasa por RLS, y declaran
--     {"role":"service_role"} en los claims para la FSM.
--   * Sin Storage de Supabase: los archivos van a Vercel Blob con ruta
--     {tenant}/{dossier}/... y el acceso se autoriza en la app.
-- =============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;
grant authenticated to current_user;

create schema if not exists auth;
create or replace function auth.jwt() returns jsonb language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
create or replace function auth.uid() returns text language sql stable set search_path = '' as $$
  select nullif(auth.jwt() ->> 'sub', '')
$$;
grant usage on schema auth to authenticated;
grant execute on function auth.jwt(), auth.uid() to authenticated;

create schema if not exists clm;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists vector   with schema extensions;

create schema if not exists app;   -- helpers internos (NO expuesto por PostgREST)
create schema if not exists ref;   -- catálogos globales + datos abiertos
grant usage on schema clm, app, ref, extensions to authenticated;

-- ----------------------------------------------------------------------- tipos
create type clm.app_role as enum (
  'ADMIN_ENTIDAD','ELABORADOR','JEFE_AREA','PLANEACION','PRESUPUESTO',
  'COORDINADOR_CONTRATACION','REVISOR_JURIDICO','JEFE_JURIDICA','ORDENADOR_GASTO','AUDITOR');
create type clm.role_scope    as enum ('UNIT','SUBTREE','TENANT');
create type clm.unit_kind     as enum ('DEPENDENCIA','AREA','UNIDAD_CONTRATACION','JURIDICA_CENTRAL');
create type clm.dossier_state as enum (
  'BORRADOR','PENDIENTE_CDP','EN_COLA_JURIDICA','EN_REVISION_JURIDICA','EN_SUBSANACION',
  'EN_CADENA_VOBO','APROBADO','EN_SELECCION','ADJUDICADO','PERFECCIONADO',
  'EJECUCION_HABILITADA','DESISTIDO');
create type clm.obs_severity  as enum ('BLOQUEANTE','SUSTANCIAL','FORMA');
create type clm.obs_status    as enum ('ABIERTA','RESPONDIDA','ACEPTADA','REABIERTA','DESISTIDA');
create type clm.step_status   as enum ('PENDIENTE','APROBADO','RECHAZADO','ANULADO');

-- ------------------------------------------------------------ utilidades puras
create function app.sha256(p text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(convert_to(coalesce(p, ''), 'UTF8'), 'sha256'), 'hex')
$$;

create function app.ts_utc(p timestamptz) returns text
language sql immutable set search_path = '' as $$
  select to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
$$;

create function app.try_uuid(p text) returns uuid
language plpgsql immutable set search_path = '' as $$
begin
  return p::uuid;
exception when others then
  return null;
end $$;

create function app.req(p jsonb, k text) returns text
language plpgsql immutable set search_path = '' as $$
begin
  if coalesce(p ->> k, '') = '' then
    raise exception 'PAYLOAD_INCOMPLETO' using detail = k;
  end if;
  return p ->> k;
end $$;

-- =============================================================================
-- 1. ORGANIZACIÓN
-- =============================================================================
create table clm.tenants (            -- extensión CLM de public."Tenant" (Prisma)
  id                 text primary key references public."Tenant" (id) on delete cascade,
  territorial_order  text not null check (territorial_order in ('NACIONAL','DEPARTAMENTAL','DISTRITAL','MUNICIPAL')),
  contracting_regime text not null default 'GENERAL' check (contracting_regime in ('GENERAL','ESPECIAL')),
  settings           jsonb not null default '{
    "rigor": {"min_sample": 5, "default_level": 2, "level2_mape": 0.10, "level3_mape": 0.25},
    "authorship_statement": "Declaro que revisé, comprendo y asumo la autoría de este documento, incluido el contenido sugerido por herramientas de IA."
  }'::jsonb,
  created_at         timestamptz not null default now()
);

create table clm.organizational_units (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  text not null references clm.tenants (id),
  parent_id  uuid,
  kind       clm.unit_kind not null,
  code       text not null,
  name       text not null,
  path       uuid[] not null default '{}',      -- raíz..self, mantenido por trigger
  active     boolean not null default true,
  unique (tenant_id, code),
  unique (tenant_id, id),
  foreign key (tenant_id, parent_id) references clm.organizational_units (tenant_id, id)
);
create index organizational_units_path on clm.organizational_units using gin (path);

create table clm.users (              -- usuarios habilitados en CLM (extensión de public."User")
  id         text primary key references public."User" (id) on delete cascade,
  tenant_id  text not null references clm.tenants (id),
  active     boolean not null default true,
  unique (tenant_id, id)
);

create table clm.user_memberships (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  text not null,
  user_id    text not null,
  unit_id    uuid not null,
  role       clm.app_role not null,
  scope      clm.role_scope not null default 'UNIT',
  valid_from date not null default current_date,
  valid_to   date,
  unique (tenant_id, user_id, unit_id, role),
  foreign key (tenant_id, user_id) references clm.users (tenant_id, id),
  foreign key (tenant_id, unit_id) references clm.organizational_units (tenant_id, id)
);
create index user_memberships_lookup on clm.user_memberships (user_id, role)
  include (tenant_id, unit_id, scope, valid_from, valid_to);

-- =============================================================================
-- 2. CONFIGURACIÓN DE GOBERNANZA (por tenant)
-- =============================================================================
create table clm.contract_types (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           text not null references clm.tenants (id),
  code                text not null,           -- PRESTACION_SERVICIOS, OBRA, SUMINISTRO, CONSULTORIA...
  name                text not null,
  requires_selection  boolean not null default false,   -- false = contratación directa
  requires_guarantees boolean not null default true,
  required_artifacts  text[] not null default '{ESTUDIO_PREVIO,ESTUDIO_MERCADO,MATRIZ_RIESGOS}',
  unique (tenant_id, code),
  unique (tenant_id, id)
);

-- Matriz de delegación: qué unidad de contratación revisa los expedientes de
-- una unidad (y su subárbol). Sin fila aplicable → JURIDICA_CENTRAL del tenant.
create table clm.review_delegations (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        text not null,
  origin_unit_id   uuid not null,
  contract_type_id uuid,                        -- null = cualquier tipología
  min_amount       numeric(18,2) not null default 0,
  max_amount       numeric(18,2),               -- exclusivo; null = sin tope
  review_unit_id   uuid not null,
  foreign key (tenant_id, origin_unit_id)   references clm.organizational_units (tenant_id, id),
  foreign key (tenant_id, review_unit_id)   references clm.organizational_units (tenant_id, id),
  foreign key (tenant_id, contract_type_id) references clm.contract_types (tenant_id, id)
);

-- Cadena de VoBo posterior al del revisor jurídico. Gana la regla más específica.
create table clm.approval_rules (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        text not null references clm.tenants (id),
  contract_type_id uuid,
  min_amount       numeric(18,2) not null default 0,
  min_rigor        smallint not null default 1 check (min_rigor between 1 and 3),
  steps            clm.app_role[] not null check (cardinality(steps) > 0),
  foreign key (tenant_id, contract_type_id) references clm.contract_types (tenant_id, id)
);

create table ref.gate_checks (
  code        text primary key,
  description text not null
);

-- Compuertas configurables (se suman a las hard_checks legales de la FSM).
create table clm.quality_gate_rules (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        text not null references clm.tenants (id),
  contract_type_id uuid,
  event            text not null,
  check_code       text not null references ref.gate_checks (code),
  min_rigor        smallint not null default 1 check (min_rigor between 1 and 3),
  params           jsonb not null default '{}',
  enabled          boolean not null default true,
  foreign key (tenant_id, contract_type_id) references clm.contract_types (tenant_id, id)
);
create index quality_gate_rules_lookup on clm.quality_gate_rules (tenant_id, event);

create table clm.normative_rules (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        text not null references clm.tenants (id),
  contract_type_id uuid,
  artifact_kind    text not null,
  code             text not null,
  kind             text not null check (kind in ('SECCION_REQUERIDA','PATRON_PROHIBIDO','PATRON_REQUERIDO')),
  pattern          text not null,               -- clave de sección o regex (~*)
  message          text not null,
  severity         clm.obs_severity not null default 'SUSTANCIAL',
  enabled          boolean not null default true,
  unique (tenant_id, code),
  foreign key (tenant_id, contract_type_id) references clm.contract_types (tenant_id, id)
);

create table clm.document_templates (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        text not null references clm.tenants (id),
  contract_type_id uuid not null,
  artifact_kind    text not null default 'CONTRATO',
  version          int not null,
  body             text not null,               -- marcadores {{ruta.al.campo}}
  active           boolean not null default true,
  unique (tenant_id, contract_type_id, artifact_kind, version),
  foreign key (tenant_id, contract_type_id) references clm.contract_types (tenant_id, id)
);

-- Transiciones de la FSM: catálogo global, no editable por tenants.
create table ref.fsm_transitions (
  from_state  clm.dossier_state not null,
  event       text not null,
  to_state    clm.dossier_state,             -- null = lo resuelve la acción (VOBO)
  actor_roles clm.app_role[] not null default '{}',
  actor_scope text not null check (actor_scope in ('ORIGIN','REVIEW','ASSIGNED','STEP','SYSTEM')),
  hard_checks text[] not null default '{}',     -- compuertas legales mínimas, no desactivables
  primary key (from_state, event)
);

-- =============================================================================
-- 3. PLANEACIÓN (Plan Anual de Adquisiciones)
-- =============================================================================
create table clm.procurement_plans (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   text not null references clm.tenants (id),
  fiscal_year smallint not null,
  version     int not null default 1,
  status      text not null default 'BORRADOR' check (status in ('BORRADOR','APROBADO','REEMPLAZADO')),
  approved_at timestamptz,
  unique (tenant_id, fiscal_year, version),
  unique (tenant_id, id)
);
create unique index procurement_plans_one_approved on clm.procurement_plans (tenant_id, fiscal_year)
  where status = 'APROBADO';

create table clm.procurement_plan_items (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       text not null,
  plan_id         uuid not null,
  unit_id         uuid not null,                -- dependencia dueña de la línea
  code            text not null,
  description     text not null,
  unspsc_codes    text[] not null check (cardinality(unspsc_codes) > 0),
  estimated_value numeric(18,2) not null check (estimated_value > 0),
  modality        text not null,
  expected_start  date not null,
  duration_days   int not null check (duration_days > 0),
  unique (tenant_id, id),
  unique (plan_id, code),
  foreign key (tenant_id, plan_id) references clm.procurement_plans (tenant_id, id),
  foreign key (tenant_id, unit_id) references clm.organizational_units (tenant_id, id)
);

-- =============================================================================
-- 4. EXPEDIENTE, ARTEFACTOS Y VERSIONES
-- =============================================================================
create table clm.dossiers (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               text not null,
  number                  bigint generated always as identity, -- ponytail: consecutivo global; por tenant/vigencia si la entidad lo exige
  origin_unit_id          uuid not null,
  review_unit_id          uuid,                  -- resuelto al expedir CDP (matriz de delegación)
  contract_type_id        uuid not null,
  plan_item_id            uuid,
  fiscal_year             smallint not null default extract(year from now())::smallint,
  object                  text not null check (length(object) between 20 and 4000),
  estimated_value         numeric(18,2) not null check (estimated_value > 0),
  estimated_duration_days int not null check (estimated_duration_days > 0),
  unspsc_codes            text[] not null default '{}',
  state                   clm.dossier_state not null default 'BORRADOR',
  state_version           int not null default 0,  -- concurrencia optimista
  rigor_level             smallint not null default 2 check (rigor_level between 1 and 3),
  assigned_reviewer_id    text,
  review_round            int not null default 0,  -- +1 en cada devolución
  approval_chain          int not null default 0,  -- +1 en cada cadena de VoBo abierta
  market_scanned_at       timestamptz,
  seal_hash               text,
  sealed_at               timestamptz,
  created_by              text not null default auth.uid(),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, origin_unit_id)       references clm.organizational_units (tenant_id, id),
  foreign key (tenant_id, review_unit_id)       references clm.organizational_units (tenant_id, id),
  foreign key (tenant_id, contract_type_id)     references clm.contract_types (tenant_id, id),
  foreign key (tenant_id, plan_item_id)         references clm.procurement_plan_items (tenant_id, id),
  foreign key (tenant_id, assigned_reviewer_id) references clm.users (tenant_id, id),
  foreign key (tenant_id, created_by)           references clm.users (tenant_id, id)
);
create index dossiers_tenant_state  on clm.dossiers (tenant_id, state) include (origin_unit_id, review_unit_id, assigned_reviewer_id);
create index dossiers_tenant_origin on clm.dossiers (tenant_id, origin_unit_id);
create index dossiers_tenant_review on clm.dossiers (tenant_id, review_unit_id, state);
create index dossiers_reviewer      on clm.dossiers (assigned_reviewer_id) where assigned_reviewer_id is not null;
create index dossiers_plan_item     on clm.dossiers (plan_item_id) where state <> 'DESISTIDO';

create table clm.artifacts (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          text not null,
  dossier_id         uuid not null,
  kind               text not null,             -- ESTUDIO_PREVIO, ESTUDIO_MERCADO, MATRIZ_RIESGOS, CONTRATO...
  stage              text not null default 'PRECONTRACTUAL' check (stage in ('PRECONTRACTUAL','CONTRACTUAL')),
  title              text not null,
  draft              jsonb not null default '{"blocks": []}' check (jsonb_typeof(draft -> 'blocks') = 'array'),
  current_version_id uuid,
  sealed_hash        text,
  sealed_at          timestamptz,
  unique (tenant_id, dossier_id, kind),
  unique (tenant_id, id),
  foreign key (tenant_id, dossier_id) references clm.dossiers (tenant_id, id)
);

create table clm.artifact_versions (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    text not null,
  dossier_id   uuid not null,
  artifact_id  uuid not null,
  major        int not null,                    -- = review_round + 1  (v1.x, v2.x tras cada devolución)
  minor        int not null,                    -- guardados dentro de la misma ronda
  label        text generated always as ('v' || major::text || '.' || minor::text) stored,
  content      jsonb not null,                  -- snapshot del borrador (lo copia el trigger)
  metadata     jsonb not null default '{}',
  content_hash text not null,                   -- SHA-256 de content
  storage_path text,                            -- PDF renderizado en Storage (opcional)
  created_by   text not null,
  created_at   timestamptz not null default now(),
  unique (artifact_id, major, minor),
  unique (tenant_id, id),
  foreign key (tenant_id, artifact_id) references clm.artifacts (tenant_id, id),
  foreign key (tenant_id, dossier_id)  references clm.dossiers (tenant_id, id)
);
alter table clm.artifacts add foreign key (tenant_id, current_version_id)
  references clm.artifact_versions (tenant_id, id);

create table clm.authorship_attestations (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      text not null,
  dossier_id     uuid not null,
  version_id     uuid not null unique,
  user_id        text not null,
  statement      text not null,
  ai_block_count int not null,
  statement_hash text not null,
  attested_at    timestamptz not null default now(),
  foreign key (tenant_id, version_id) references clm.artifact_versions (tenant_id, id)
);

-- =============================================================================
-- 5. REVISIÓN, OBSERVACIONES Y VoBo
-- =============================================================================
create table clm.observations (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   text not null,
  dossier_id  uuid not null,
  round       int not null,
  artifact_id uuid not null,
  version_id  uuid not null,                    -- versión observada (la vigente al observar)
  block_id    text,                             -- ancla al bloque; null = observación general
  severity    clm.obs_severity not null,
  category    text not null,                    -- JURIDICA, TECNICA, PRESUPUESTAL, FORMA...
  body        text not null check (length(body) >= 10),
  status      clm.obs_status not null default 'ABIERTA',
  created_by  text not null,
  created_at  timestamptz not null default now(),
  closed_by   text,
  closed_at   timestamptz,
  unique (tenant_id, id),
  foreign key (tenant_id, dossier_id)  references clm.dossiers (tenant_id, id),
  foreign key (tenant_id, artifact_id) references clm.artifacts (tenant_id, id),
  foreign key (tenant_id, version_id)  references clm.artifact_versions (tenant_id, id)
);
create index observations_dossier on clm.observations (dossier_id, status);

create table clm.observation_responses (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            text not null,
  dossier_id           uuid not null,
  observation_id       uuid not null,
  resolution           text not null check (resolution in ('CORREGIDA','NO_PROCEDE')),
  justification        text not null check (length(justification) >= 20),
  corrected_version_id uuid,
  created_by           text not null,
  created_at           timestamptz not null default now(),
  check (resolution <> 'CORREGIDA' or corrected_version_id is not null),
  foreign key (tenant_id, observation_id)       references clm.observations (tenant_id, id),
  foreign key (tenant_id, corrected_version_id) references clm.artifact_versions (tenant_id, id)
);

create table clm.approval_steps (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     text not null,
  dossier_id    uuid not null,
  chain_no      int not null,
  seq           int not null,
  role          clm.app_role not null,
  unit_id       uuid not null,                  -- unidad sobre la que se exige el rol
  status        clm.step_status not null default 'PENDIENTE',
  manifest_hash text not null,                  -- lo que se aprueba (hash de versiones vigentes)
  decided_by    text,
  decided_at    timestamptz,
  comment       text,
  prev_hash     text,
  step_hash     text,                           -- encadena VoBo: sha256(prev_hash | ... | manifest)
  unique (dossier_id, chain_no, seq),
  foreign key (tenant_id, dossier_id) references clm.dossiers (tenant_id, id)
);

-- =============================================================================
-- 6. HITOS PRESUPUESTALES Y LEGALES
-- =============================================================================
create table clm.budget_certificates (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    text not null,
  dossier_id   uuid not null,
  kind         text not null check (kind in ('CDP','RP')),
  number       text,
  budget_line  text,
  amount       numeric(18,2) not null check (amount > 0),
  status       text not null check (status in ('SOLICITADO','EXPEDIDO','ANULADO')),
  requested_at timestamptz not null default now(),
  issued_by    text,
  issued_at    timestamptz,
  unique (tenant_id, kind, number),
  foreign key (tenant_id, dossier_id) references clm.dossiers (tenant_id, id)
);

create table clm.contracts (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            text not null,
  dossier_id           uuid not null,
  contract_number      text not null,
  contractor_nit       text not null,
  contractor_name      text not null,
  value                numeric(18,2) not null check (value > 0),
  duration_days        int not null check (duration_days > 0),
  awarded_at           timestamptz not null default now(),
  signed_at            timestamptz,             -- PERFECCIONAMIENTO
  signature_request_id uuid,
  execution_enabled_at timestamptz,             -- HABILITACIÓN DE EJECUCIÓN
  start_date           date,                    -- acta de inicio
  unique (tenant_id, dossier_id),
  unique (tenant_id, contract_number),
  unique (tenant_id, id),
  foreign key (tenant_id, dossier_id) references clm.dossiers (tenant_id, id)
);

create table clm.guarantees (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      text not null,
  dossier_id     uuid not null,
  contract_id    uuid not null,
  coverage       text not null,                 -- CUMPLIMIENTO, CALIDAD, SALARIOS, RCE...
  insurer        text not null,
  policy_number  text not null,
  insured_amount numeric(18,2) not null check (insured_amount > 0),
  valid_from     date not null,
  valid_to       date not null check (valid_to > valid_from),
  document_path  text,
  status         text not null default 'RADICADA' check (status in ('RADICADA','APROBADA','RECHAZADA')),
  reviewed_by    text,
  reviewed_at    timestamptz,
  foreign key (tenant_id, contract_id) references clm.contracts (tenant_id, id),
  foreign key (tenant_id, dossier_id)  references clm.dossiers (tenant_id, id)
);

create table clm.supervision_assignments (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            text not null,
  dossier_id           uuid not null,
  contract_id          uuid not null,
  kind                 text not null check (kind in ('SUPERVISION','INTERVENTORIA')),
  supervisor_user_id   text,
  external_name        text,
  designation_doc_path text,
  designated_by        text not null,
  designated_at        timestamptz not null default now(),
  revoked_at           timestamptz,
  check (supervisor_user_id is not null or external_name is not null),
  foreign key (tenant_id, contract_id)        references clm.contracts (tenant_id, id),
  foreign key (tenant_id, dossier_id)         references clm.dossiers (tenant_id, id),
  foreign key (tenant_id, supervisor_user_id) references clm.users (tenant_id, id)
);

create table clm.contract_modifications (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   text not null,
  dossier_id  uuid not null,
  contract_id uuid not null,
  kind        text not null check (kind in ('ADICION','REDUCCION','PRORROGA','SUSPENSION','CESION')),
  value_delta numeric(18,2) not null default 0,
  days_delta  int not null default 0,
  signed_at   date not null,
  created_by  text not null default auth.uid(),
  foreign key (tenant_id, contract_id) references clm.contracts (tenant_id, id),
  foreign key (tenant_id, dossier_id)  references clm.dossiers (tenant_id, id)
);

create table clm.signature_requests (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           text not null,
  dossier_id          uuid not null,
  artifact_version_id uuid not null,            -- versión sellada que se firma
  provider            text not null,            -- adaptador: 'certicamara', 'docusign', 'gse'...
  external_id         text,
  pdf_sha256          text not null,            -- hash del PDF exacto enviado al proveedor
  signers             jsonb not null,
  status              text not null default 'CREADA' check (status in ('CREADA','ENVIADA','FIRMADA','RECHAZADA','EXPIRADA')),
  evidence            jsonb,                    -- respuesta del proveedor (certificados, sellos de tiempo)
  created_by          text not null default auth.uid(),
  created_at          timestamptz not null default now(),
  completed_at        timestamptz,
  foreign key (tenant_id, artifact_version_id) references clm.artifact_versions (tenant_id, id),
  foreign key (tenant_id, dossier_id)          references clm.dossiers (tenant_id, id)
);

-- =============================================================================
-- 7. MERCADO, INTEGRIDAD E IA
-- =============================================================================
create table clm.market_quotes (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     text not null,
  dossier_id    uuid not null,
  supplier_nit  text not null,
  supplier_name text not null,
  amount        numeric(18,2) not null check (amount > 0),
  quote_date    date not null,
  document_path text,
  created_by    text not null default auth.uid(),
  created_at    timestamptz not null default now(),
  foreign key (tenant_id, dossier_id) references clm.dossiers (tenant_id, id)
);

create table clm.integrity_findings (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     text not null,
  dossier_id    uuid not null,
  kind          text not null check (kind in ('VINCULO_CRUZADO','INHABILIDAD','SIN_REGISTRO','CIIU_INCONSISTENTE','COTIZACION_ATIPICA')),
  severity      clm.obs_severity not null,
  subjects      text[] not null,                -- NITs involucrados
  evidence      jsonb not null,
  status        text not null default 'ABIERTO' check (status in ('ABIERTO','DESCARTADO_JUSTIFICADO','CONFIRMADO','SUPERADO')),
  justification text,
  created_at    timestamptz not null default now(),
  check (status <> 'DESCARTADO_JUSTIFICADO' or length(justification) >= 30),
  foreign key (tenant_id, dossier_id) references clm.dossiers (tenant_id, id)
);

create table clm.ai_generations (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      text not null,
  dossier_id     uuid not null,
  artifact_id    uuid not null,
  block_id       text not null,
  task           text not null check (task in ('JUSTIFICACION','OBJETO','ALCANCE','OBLIGACIONES','MATRIZ_RIESGOS','VALOR_ESTIMADO','REVISION_NORMATIVA')),
  model          text not null,
  prompt_version text not null,
  prompt_hash    text not null,
  citations      jsonb not null default '[]',   -- [{kind:'public_chunk'|'tenant_chunk'|'price_benchmark'|'public_document', id}]
  output         jsonb not null,
  decision       text not null default 'PENDIENTE' check (decision in ('PENDIENTE','ACEPTADA','EDITADA','DESCARTADA')),
  created_by     text not null default auth.uid(),
  created_at     timestamptz not null default now(),
  -- Mitigación de alucinaciones: ningún valor sin respaldo indexado. Hard stop en la BD.
  check (task <> 'VALOR_ESTIMADO' or jsonb_path_exists(citations,
         '$[*] ? (@.kind == "price_benchmark" || @.kind == "public_document")')),
  foreign key (tenant_id, artifact_id) references clm.artifacts (tenant_id, id),
  foreign key (tenant_id, dossier_id)  references clm.dossiers (tenant_id, id)
);

-- Embeddings privados (versiones inmutables de artefactos del tenant).
-- ponytail: dimensión fija 1024; cambiar de modelo = columna nueva + reindexado.
create table clm.tenant_chunks (
  id                  bigint generated always as identity primary key,
  tenant_id           text not null,
  unit_id             uuid not null,
  dossier_id          uuid not null,
  artifact_version_id uuid not null,
  block_id            text,
  content             text not null,
  embedding           extensions.vector(1024) not null,
  embedding_model     text not null,
  created_at          timestamptz not null default now(),
  foreign key (tenant_id, artifact_version_id) references clm.artifact_versions (tenant_id, id),
  foreign key (tenant_id, dossier_id)          references clm.dossiers (tenant_id, id)
);
create index tenant_chunks_scope on clm.tenant_chunks (tenant_id, unit_id);
create index tenant_chunks_hnsw  on clm.tenant_chunks using hnsw (embedding extensions.vector_cosine_ops);

-- Datos abiertos compartidos (SECOP, guías CCE, registros). Sin tenant, solo lectura.
create table ref.public_documents (
  id           uuid primary key default gen_random_uuid(),
  source       text not null,                   -- SECOP_II_CONTRATOS, SECOP_II_PROCESOS, CCE_GUIA...
  source_ref   text not null,
  entity_nit   text,
  unspsc_codes text[] not null default '{}',
  title        text not null,
  body         text not null,
  amount       numeric(18,2),
  signed_at    date,
  metadata     jsonb not null default '{}',
  ingested_at  timestamptz not null default now(),
  unique (source, source_ref)
);
create index public_documents_unspsc on ref.public_documents using gin (unspsc_codes);

create table ref.public_chunks (
  id              bigint generated always as identity primary key,
  document_id     uuid not null references ref.public_documents (id) on delete cascade,
  chunk_no        int not null,
  unspsc_segment  text,                         -- 2 primeros dígitos (segmento UNSPSC)
  content         text not null,
  embedding       extensions.vector(1024) not null,
  embedding_model text not null,
  unique (document_id, chunk_no)
);
create index public_chunks_hnsw on ref.public_chunks using hnsw (embedding extensions.vector_cosine_ops);

create table ref.price_benchmarks (
  unspsc_code  text not null,
  unit         text not null,
  p25          numeric(18,2) not null,
  p50          numeric(18,2) not null,
  p75          numeric(18,2) not null,
  sample_size  int not null,
  period_start date not null,
  period_end   date not null,
  primary key (unspsc_code, unit, period_end)
);

-- Registro mercantil/tributario normalizado (RUES, DIAN). Identificadores de
-- personas naturales se guardan como SHA-256: se comparan, no se exponen.
create table ref.company_registry (
  nit                text primary key,
  name               text not null,
  ciiu_codes         text[] not null default '{}',
  legal_rep_hashes   text[] not null default '{}',
  shareholder_hashes text[] not null default '{}',
  address_hash       text,
  phone_hash         text,
  status             text not null,             -- ACTIVA, CANCELADA, EN_LIQUIDACION
  source             text not null,
  fetched_at         timestamptz not null default now()
);
create table ref.sanctions (
  nit         text not null,
  source      text not null,                    -- SIRI (Procuraduría), SECOP multas, boletín Contraloría
  kind        text not null,
  valid_until date,
  detail      jsonb not null default '{}',
  primary key (nit, source, kind)
);
create table ref.unspsc_ciiu (
  unspsc_class text not null,                   -- 6 dígitos
  ciiu         text not null,
  primary key (unspsc_class, ciiu)
);

-- =============================================================================
-- 8. BITÁCORA INMUTABLE
-- =============================================================================
create table clm.audit_events (
  id            bigint generated always as identity primary key,
  tenant_id     text not null,
  unit_id       uuid,
  dossier_id    uuid,
  actor_id      text,
  actor_role    text,
  action        text not null,
  entity        text not null,
  entity_id     uuid,
  artifact_hash text,
  payload       jsonb not null default '{}',
  prev_hash     text,
  event_hash    text not null,
  occurred_at   timestamptz not null              -- UTC (timestamptz) fijado por app.audit
);
create index audit_events_tenant  on clm.audit_events (tenant_id, id);
create index audit_events_dossier on clm.audit_events (dossier_id, id) where dossier_id is not null;

-- =============================================================================
-- 9. HELPERS DE SEGURIDAD (usados por RLS)
-- =============================================================================
create function app.tenant_id() returns text
language sql stable set search_path = '' as $$
  -- La app fija los claims desde la sesión de Auth.js (src/lib/db/clm.ts); el usuario no los toca.
  select nullif(auth.jwt() -> 'app_metadata' ->> 'tenant_id', '')
$$;

create function app.user_covers(p_user text, p_roles clm.app_role[], p_unit uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from clm.organizational_units u
    join clm.user_memberships m on m.tenant_id = u.tenant_id
    join clm.users usr on usr.id = m.user_id and usr.active
    where u.id = p_unit
      and m.user_id = p_user
      and m.role = any (p_roles)
      and current_date >= m.valid_from
      and (m.valid_to is null or current_date <= m.valid_to)
      and case m.scope
            when 'TENANT'  then true
            when 'SUBTREE' then m.unit_id = any (u.path)   -- la membresía está en un ancestro (o es la unidad)
            else m.unit_id = p_unit
          end)
$$;

create function app.covers(p_roles clm.app_role[], p_unit uuid) returns boolean
language sql stable set search_path = '' as $$
  select app.user_covers((select auth.uid()), p_roles, p_unit)
$$;

create function app.has_tenant_role(p_roles clm.app_role[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from clm.user_memberships m
    where m.user_id = (select auth.uid())
      and m.tenant_id = app.tenant_id()
      and m.scope = 'TENANT'
      and m.role = any (p_roles)
      and current_date >= m.valid_from
      and (m.valid_to is null or current_date <= m.valid_to))
$$;

-- Visibilidad jerárquica del expediente. Se evalúa sobre la fila (no por id) para
-- que también sirva en INSERT ... RETURNING, donde la fila aún no es visible.
create function app.can_read_dossier_row(d clm.dossiers) returns boolean
language sql stable security definer set search_path = '' as $$
  select d.tenant_id = app.tenant_id()
     and ( d.created_by = (select auth.uid())
        or d.assigned_reviewer_id = (select auth.uid())
        or app.covers('{ELABORADOR,JEFE_AREA,PLANEACION,PRESUPUESTO,ORDENADOR_GASTO,AUDITOR,ADMIN_ENTIDAD}', d.origin_unit_id)
        or (d.review_unit_id is not null
            and app.covers('{COORDINADOR_CONTRATACION,REVISOR_JURIDICO,JEFE_JURIDICA}', d.review_unit_id))
        or exists (select 1 from clm.approval_steps s
                    where s.dossier_id = d.id and s.chain_no = d.approval_chain
                      and app.covers(array[s.role], s.unit_id)))
$$;

create function app.can_read_dossier(p_dossier uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select app.can_read_dossier_row(d) from clm.dossiers d where d.id = p_dossier), false)
$$;

-- Edición del área técnica: solo en BORRADOR / EN_SUBSANACION (congela a todos los demás).
create function app.can_edit_dossier(p_dossier uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from clm.dossiers d
    where d.id = p_dossier
      and d.tenant_id = app.tenant_id()
      and d.state in ('BORRADOR','EN_SUBSANACION')
      and (d.created_by = (select auth.uid()) or app.covers('{ELABORADOR,JEFE_AREA}', d.origin_unit_id)))
$$;

-- Observar: revisor asignado en EN_REVISION_JURIDICA, o titular del VoBo en turno.
create function app.can_observe(p_dossier uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from clm.dossiers d
    where d.id = p_dossier
      and d.tenant_id = app.tenant_id()
      and ( (d.state = 'EN_REVISION_JURIDICA' and d.assigned_reviewer_id = (select auth.uid()))
         or (d.state = 'EN_CADENA_VOBO' and exists (
               select 1 from clm.approval_steps s
               where s.dossier_id = d.id and s.chain_no = d.approval_chain and s.status = 'PENDIENTE'
                 and s.seq = (select min(s2.seq) from clm.approval_steps s2
                               where s2.dossier_id = d.id and s2.chain_no = d.approval_chain and s2.status = 'PENDIENTE')
                 and app.covers(array[s.role], s.unit_id)))))
$$;

-- =============================================================================
-- 10. ORGANIGRAMA Y DELEGACIÓN
-- =============================================================================
create function app.tg_unit_path() returns trigger
language plpgsql set search_path = '' as $$
declare parent_path uuid[];
begin
  if new.parent_id is null then
    new.path := array[new.id];
  else
    select p.path into parent_path from clm.organizational_units p where p.id = new.parent_id;
    if new.id = any (parent_path) then
      raise exception 'ORGANIGRAMA_CICLICO' using detail = new.id::text;
    end if;
    new.path := parent_path || new.id;
  end if;
  return new;
end $$;
create trigger unit_path before insert or update of parent_id on clm.organizational_units
  for each row execute function app.tg_unit_path();

create function app.tg_unit_path_cascade() returns trigger
language plpgsql set search_path = '' as $$
begin
  update clm.organizational_units set parent_id = parent_id where parent_id = new.id;  -- recalcula hijos (recursivo)
  return null;
end $$;
create trigger unit_path_cascade after update of parent_id on clm.organizational_units
  for each row when (old.path is distinct from new.path) execute function app.tg_unit_path_cascade();

-- Unidad de contratación competente: el ancestro más cercano con delegación
-- aplicable (tipología y cuantía); si no hay, la jurídica central.
create function app.resolve_review_unit(p_tenant text, p_origin uuid, p_type uuid, p_amount numeric) returns uuid
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select d.review_unit_id
       from clm.organizational_units o
       cross join lateral unnest(o.path) with ordinality as a(unit_id, depth)
       join clm.review_delegations d on d.tenant_id = o.tenant_id and d.origin_unit_id = a.unit_id
      where o.id = p_origin and o.tenant_id = p_tenant
        and (d.contract_type_id is null or d.contract_type_id = p_type)
        and p_amount >= d.min_amount and (d.max_amount is null or p_amount < d.max_amount)
      order by a.depth desc, (d.contract_type_id is not null) desc, d.min_amount desc
      limit 1),
    (select u.id from clm.organizational_units u
      where u.tenant_id = p_tenant and u.kind = 'JURIDICA_CENTRAL' and u.active
      order by u.code limit 1))
$$;

-- =============================================================================
-- 11. AUDITORÍA ENCADENADA + APPEND-ONLY
-- =============================================================================
create function app.audit_hash(e clm.audit_events) returns text
language sql immutable set search_path = '' as $$
  select app.sha256(concat_ws('|', e.prev_hash, e.tenant_id, e.unit_id, e.dossier_id, e.actor_id, e.actor_role,
                              e.action, e.entity, e.entity_id, e.artifact_hash, e.payload::text, app.ts_utc(e.occurred_at)))
$$;

create function app.audit(p_tenant text, p_unit uuid, p_dossier uuid, p_action text, p_entity text,
                          p_entity_id uuid, p_hash text, p_payload jsonb, p_role text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare e clm.audit_events;
begin
  -- ponytail: un lock por tenant serializa la cadena; particionar por dependencia si la escritura satura
  perform pg_advisory_xact_lock(hashtextextended('audit:' || p_tenant::text, 0));
  e.tenant_id     := p_tenant;
  e.dossier_id    := p_dossier;
  e.unit_id       := coalesce(p_unit, (select d.origin_unit_id from clm.dossiers d where d.id = p_dossier));
  e.actor_id      := auth.uid();
  e.actor_role    := coalesce(p_role,
                       (select string_agg(distinct m.role::text, ',') from clm.user_memberships m
                         where m.user_id = e.actor_id and m.tenant_id = p_tenant),
                       auth.jwt() ->> 'role');
  e.action        := p_action;
  e.entity        := p_entity;
  e.entity_id     := p_entity_id;
  e.artifact_hash := p_hash;
  e.payload       := coalesce(p_payload, '{}');
  e.occurred_at   := clock_timestamp();
  select a.event_hash into e.prev_hash from clm.audit_events a
   where a.tenant_id = p_tenant order by a.id desc limit 1;
  e.event_hash    := app.audit_hash(e);
  insert into clm.audit_events (tenant_id, unit_id, dossier_id, actor_id, actor_role, action, entity, entity_id,
                                   artifact_hash, payload, prev_hash, event_hash, occurred_at)
  values (e.tenant_id, e.unit_id, e.dossier_id, e.actor_id, e.actor_role, e.action, e.entity, e.entity_id,
          e.artifact_hash, e.payload, e.prev_hash, e.event_hash, e.occurred_at);
end $$;

-- Devuelve el id del primer evento roto de la cadena del tenant (null = íntegra).
create function app.verify_audit_chain(p_tenant text) returns bigint
language plpgsql stable security definer set search_path = '' as $$
declare e clm.audit_events; v_prev text;
begin
  for e in select * from clm.audit_events where tenant_id = p_tenant order by id loop
    if e.prev_hash is distinct from v_prev or e.event_hash <> app.audit_hash(e) then
      return e.id;
    end if;
    v_prev := e.event_hash;
  end loop;
  return null;
end $$;

create function app.tg_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r jsonb := to_jsonb(case when tg_op = 'DELETE' then old else new end);
begin
  perform app.audit(
    r ->> 'tenant_id', null,
    app.try_uuid(case when tg_table_name = 'dossiers' then r ->> 'id' else r ->> 'dossier_id' end),
    lower(tg_op), tg_table_name, app.try_uuid(r ->> 'id'), r ->> 'content_hash',
    r - '{content,draft,embedding,body,output}'::text[]);
  return null;
end $$;

create function app.tg_append_only() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'REGISTRO_INMUTABLE' using detail = tg_op || ' sobre ' || tg_table_name;
end $$;

do $$
declare t text;
begin
  foreach t in array array['audit_events','artifact_versions','authorship_attestations','observation_responses'] loop
    execute format('create trigger %I before update or delete on clm.%I for each row execute function app.tg_append_only()', t || '_append_only', t);
    execute format('create trigger %I before truncate on clm.%I for each statement execute function app.tg_append_only()', t || '_no_truncate', t);
  end loop;
  -- VoBo decididos son inmutables (los pendientes pueden pasar a decididos/anulados una sola vez)
  -- Eventos auditados automáticamente (las transiciones se auditan dentro de clm.transition):
  foreach t in array array['artifact_versions','authorship_attestations','observations','observation_responses',
                           'market_quotes','integrity_findings','ai_generations','signature_requests',
                           'contract_modifications','user_memberships','organizational_units',
                           'quality_gate_rules','approval_rules','review_delegations','normative_rules','document_templates'] loop
    execute format('create trigger %I after insert or update or delete on clm.%I for each row execute function app.tg_audit()', t || '_audit', t);
  end loop;
  execute 'create trigger dossiers_audit after insert on clm.dossiers for each row execute function app.tg_audit()';
end $$;

create function app.tg_step_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' or old.status <> 'PENDIENTE' then
    raise exception 'REGISTRO_INMUTABLE' using detail = 'VoBo ya decidido';
  end if;
  return new;
end $$;
create trigger approval_steps_guard before update or delete on clm.approval_steps
  for each row execute function app.tg_step_guard();

-- =============================================================================
-- 12. EXPEDIENTE: GUARDAS DE INTEGRIDAD (+ gemelo de datos, que el rigor necesita)
-- =============================================================================
create function app.in_transition() returns boolean
language sql stable set search_path = '' as $$
  select coalesce(current_setting('app.in_transition', true), '') = 'on'
$$;

-- =============================================================================
-- 15. GEMELO DE DATOS: precisión de la planeación → rigor
-- (definido antes de los triggers del expediente porque app.compute_rigor lo usa)
-- =============================================================================
create view clm.planning_accuracy with (security_invoker = true) as
select d.tenant_id, d.origin_unit_id, d.contract_type_id, d.id as dossier_id, c.id as contract_id,
       d.estimated_value                                   as planned_value,
       c.value + coalesce(m.value_delta, 0)                as final_value,
       (c.value + coalesce(m.value_delta, 0) - d.estimated_value) / d.estimated_value as budget_variance,
       d.estimated_duration_days                           as planned_days,
       c.duration_days + coalesce(m.days_delta, 0)         as actual_days,
       (c.duration_days + coalesce(m.days_delta, 0) - d.estimated_duration_days)::numeric
         / d.estimated_duration_days                       as schedule_variance,
       c.start_date - i.expected_start                     as start_delay_days,
       c.start_date
from clm.dossiers d
join clm.contracts c on c.dossier_id = d.id
left join clm.procurement_plan_items i on i.id = d.plan_item_id
left join lateral (select sum(x.value_delta) as value_delta, sum(x.days_delta) as days_delta
                     from clm.contract_modifications x where x.contract_id = c.id) m on true
where c.start_date is not null;

-- ponytail: refresco completo nocturno (pg_cron); concurrente si el volumen lo pide.
create materialized view app.unit_planning_scores as
select tenant_id, origin_unit_id as unit_id, contract_type_id, count(*) as n,
       avg(abs(budget_variance))   as budget_mape,
       avg(abs(schedule_variance)) as schedule_mape,
       now() as computed_at
from clm.planning_accuracy
where start_date > current_date - interval '24 months'
group by grouping sets ((tenant_id, origin_unit_id, contract_type_id), (tenant_id, origin_unit_id));

-- Rigor 1..3 según el historial de la unidad (o su ancestro más cercano con muestra suficiente).
create function app.compute_rigor(p_tenant text, p_unit uuid, p_type uuid) returns smallint
language sql stable security definer set search_path = '' as $$
  with cfg as (
    select (t.settings -> 'rigor' ->> 'min_sample')::int        as min_n,
           (t.settings -> 'rigor' ->> 'level2_mape')::numeric   as l2,
           (t.settings -> 'rigor' ->> 'level3_mape')::numeric   as l3,
           (t.settings -> 'rigor' ->> 'default_level')::smallint as dflt
      from clm.tenants t where t.id = p_tenant),
  s as (
    select greatest(sc.budget_mape, sc.schedule_mape) as err
      from clm.organizational_units u
      cross join lateral unnest(u.path) with ordinality as a(unit_id, depth)
      join app.unit_planning_scores sc on sc.tenant_id = p_tenant and sc.unit_id = a.unit_id
           and (sc.contract_type_id = p_type or sc.contract_type_id is null)
      cross join cfg
     where u.id = p_unit and sc.n >= cfg.min_n
     order by a.depth desc, (sc.contract_type_id is not null) desc
     limit 1)
  select coalesce(
           (select case when s.err >= cfg.l3 then 3 when s.err >= cfg.l2 then 2 else 1 end from s, cfg),
           (select dflt from cfg),
           2)::smallint
$$;

create function app.tg_dossier_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.state := 'BORRADOR';            new.state_version := 0;
  new.review_unit_id := null;         new.assigned_reviewer_id := null;
  new.review_round := 0;              new.approval_chain := 0;
  new.seal_hash := null;              new.sealed_at := null;
  new.market_scanned_at := null;
  new.created_by := coalesce(auth.uid(), new.created_by);
  new.rigor_level := app.compute_rigor(new.tenant_id, new.origin_unit_id, new.contract_type_id);  -- se congela
  return new;
end $$;
create trigger dossiers_insert before insert on clm.dossiers
  for each row execute function app.tg_dossier_insert();

create function app.tg_dossier_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if app.in_transition() then return new; end if;
  if (new.state, new.state_version, new.review_unit_id, new.assigned_reviewer_id, new.review_round,
      new.approval_chain, new.seal_hash, new.sealed_at, new.rigor_level, new.tenant_id,
      new.origin_unit_id, new.created_by, new.contract_type_id)
     is distinct from
     (old.state, old.state_version, old.review_unit_id, old.assigned_reviewer_id, old.review_round,
      old.approval_chain, old.seal_hash, old.sealed_at, old.rigor_level, old.tenant_id,
      old.origin_unit_id, old.created_by, old.contract_type_id) then
    raise exception 'CAMPO_CONTROLADO_POR_FSM';
  end if;
  if old.state not in ('BORRADOR','EN_SUBSANACION') then
    raise exception 'EXPEDIENTE_NO_EDITABLE' using detail = old.state::text;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger dossiers_guard before update on clm.dossiers
  for each row execute function app.tg_dossier_guard();
create trigger dossiers_no_delete before delete on clm.dossiers
  for each row execute function app.tg_append_only();

create function app.tg_artifact_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if app.in_transition() then return new; end if;
  if (new.sealed_at, new.sealed_hash, new.kind, new.stage, new.dossier_id)
     is distinct from (old.sealed_at, old.sealed_hash, old.kind, old.stage, old.dossier_id) then
    raise exception 'CAMPO_CONTROLADO_POR_FSM';
  end if;
  if (new.draft, new.title) is distinct from (old.draft, old.title)
     and (old.sealed_at is not null
          or not exists (select 1 from clm.dossiers d
                          where d.id = old.dossier_id and d.state in ('BORRADOR','EN_SUBSANACION'))) then
    raise exception 'ARTEFACTO_NO_EDITABLE';
  end if;
  return new;
end $$;
create trigger artifacts_guard before update on clm.artifacts
  for each row execute function app.tg_artifact_guard();
create trigger artifacts_no_delete before delete on clm.artifacts
  for each row execute function app.tg_append_only();

-- Versionar = congelar el borrador vigente. El cliente solo manda artifact_id (+metadata).
create function app.tg_version_snapshot() returns trigger
language plpgsql set search_path = '' as $$
declare a clm.artifacts; d clm.dossiers;
begin
  select * into a from clm.artifacts where id = new.artifact_id;
  if not found then raise exception 'ARTEFACTO_NO_ENCONTRADO'; end if;
  select * into d from clm.dossiers where id = a.dossier_id;
  if not app.in_transition() then
    if a.sealed_at is not null then raise exception 'ARTEFACTO_SELLADO'; end if;
    if d.state not in ('BORRADOR','EN_SUBSANACION') then
      raise exception 'EXPEDIENTE_NO_EDITABLE' using detail = d.state::text;
    end if;
  end if;
  new.tenant_id    := a.tenant_id;
  new.dossier_id   := a.dossier_id;
  new.content      := a.draft;
  new.content_hash := app.sha256(a.draft::text);
  new.created_by   := coalesce(auth.uid(), new.created_by);
  new.created_at   := now();
  new.major        := d.review_round + 1;
  select coalesce(max(v.minor) + 1, 0) into new.minor
    from clm.artifact_versions v where v.artifact_id = a.id and v.major = new.major;
  return new;
end $$;
create trigger artifact_versions_snapshot before insert on clm.artifact_versions
  for each row execute function app.tg_version_snapshot();

create function app.tg_version_current() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update clm.artifacts set current_version_id = new.id where id = new.artifact_id;
  return null;
end $$;
create trigger artifact_versions_current after insert on clm.artifact_versions
  for each row execute function app.tg_version_current();

create function app.tg_attestation() returns trigger
language plpgsql set search_path = '' as $$
declare v clm.artifact_versions; a clm.artifacts;
begin
  select * into v from clm.artifact_versions where id = new.version_id;
  select * into a from clm.artifacts where id = v.artifact_id;
  if a.current_version_id is distinct from v.id or v.id is null then
    raise exception 'SOLO_SE_RATIFICA_LA_VERSION_VIGENTE';
  end if;
  new.tenant_id   := v.tenant_id;
  new.dossier_id  := v.dossier_id;
  new.user_id     := auth.uid();
  new.attested_at := now();
  select t.settings ->> 'authorship_statement' into new.statement from clm.tenants t where t.id = v.tenant_id;
  select count(*) into new.ai_block_count from jsonb_array_elements(v.content -> 'blocks') b
   where b -> 'provenance' ->> 'origin' in ('AI','AI_EDITED');
  new.statement_hash := app.sha256(concat_ws('|', new.statement, v.content_hash, new.user_id, app.ts_utc(new.attested_at)));
  return new;
end $$;
create trigger authorship_attestations_fill before insert on clm.authorship_attestations
  for each row execute function app.tg_attestation();

create function app.tg_observation() returns trigger
language plpgsql set search_path = '' as $$
declare d clm.dossiers; v_current uuid;
begin
  if tg_op = 'INSERT' then
    select * into d from clm.dossiers where id = new.dossier_id;
    select a.current_version_id into v_current from clm.artifacts a
     where a.id = new.artifact_id and a.dossier_id = new.dossier_id;
    if v_current is null then raise exception 'ARTEFACTO_INVALIDO'; end if;
    new.tenant_id := d.tenant_id;  new.version_id := v_current;  new.round := d.review_round;
    new.status := 'ABIERTA';       new.created_by := auth.uid();  new.created_at := now();
    new.closed_by := null;         new.closed_at := null;
    return new;
  end if;
  if (to_jsonb(new) - '{status,closed_by,closed_at}'::text[]) <> (to_jsonb(old) - '{status,closed_by,closed_at}'::text[]) then
    raise exception 'OBSERVACION_INMUTABLE';
  end if;
  if not ( (old.status in ('ABIERTA','REABIERTA') and new.status = 'RESPONDIDA')
        or (old.status = 'ABIERTA'    and new.status = 'DESISTIDA')
        or (old.status = 'RESPONDIDA' and new.status in ('ACEPTADA','REABIERTA'))) then
    raise exception 'TRANSICION_DE_OBSERVACION_INVALIDA' using detail = old.status || ' -> ' || new.status;
  end if;
  if new.status in ('ACEPTADA','DESISTIDA') then
    new.closed_by := auth.uid();  new.closed_at := now();
  end if;
  return new;
end $$;
create trigger observations_fill before insert or update on clm.observations
  for each row execute function app.tg_observation();
create trigger observations_no_delete before delete on clm.observations
  for each row execute function app.tg_append_only();

-- Respuesta punto a punto: marca la observación RESPONDIDA (definer: el elaborador no puede tocar observaciones).
create function app.tg_response() returns trigger
language plpgsql security definer set search_path = '' as $$
declare o clm.observations; d clm.dossiers; v clm.artifact_versions;
begin
  select * into o from clm.observations where id = new.observation_id for update;
  if not found or o.tenant_id is distinct from app.tenant_id() or not app.can_edit_dossier(o.dossier_id) then
    raise exception 'SIN_PERMISO' using errcode = '42501';
  end if;
  select * into d from clm.dossiers where id = o.dossier_id;
  if d.state <> 'EN_SUBSANACION' then raise exception 'SOLO_EN_SUBSANACION'; end if;
  if o.status not in ('ABIERTA','REABIERTA') then raise exception 'OBSERVACION_NO_PENDIENTE'; end if;
  if new.resolution = 'CORREGIDA' then
    select * into v from clm.artifact_versions where id = new.corrected_version_id;
    if v.artifact_id is distinct from o.artifact_id or v.major <> d.review_round + 1 then
      raise exception 'VERSION_CORRECTIVA_INVALIDA'
        using detail = 'Debe ser una versión del mismo artefacto creada en esta subsanación';
    end if;
  end if;
  new.tenant_id := o.tenant_id;  new.dossier_id := o.dossier_id;
  new.created_by := auth.uid();  new.created_at := now();
  update clm.observations set status = 'RESPONDIDA' where id = o.id;
  return new;
end $$;
create trigger observation_responses_fill before insert on clm.observation_responses
  for each row execute function app.tg_response();

create function app.tg_signature_request() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (select 1 from clm.artifact_versions v join clm.artifacts a on a.id = v.artifact_id
                  where v.id = new.artifact_version_id and v.dossier_id = new.dossier_id
                    and a.kind = 'CONTRATO' and a.current_version_id = v.id and a.sealed_at is not null) then
    raise exception 'SOLO_SE_FIRMA_EL_CONTRATO_SELLADO';
  end if;
  new.status := 'CREADA';  new.created_by := coalesce(auth.uid(), new.created_by);
  return new;
end $$;
create trigger signature_requests_fill before insert on clm.signature_requests
  for each row execute function app.tg_signature_request();

-- =============================================================================
-- 13. COMPUERTAS DE CALIDAD
-- =============================================================================
create function app.manifest_hash(p_dossier uuid) returns text
language sql stable security definer set search_path = '' as $$
  select app.sha256(coalesce(string_agg(a.kind || ':' || v.content_hash, '|' order by a.kind), ''))
    from clm.artifacts a
    join clm.artifact_versions v on v.id = a.current_version_id
   where a.dossier_id = p_dossier and a.stage = 'PRECONTRACTUAL'
$$;

create function app.normative_findings(p_dossier uuid)
returns table (code text, severity clm.obs_severity, message text, artifact_kind text)
language sql stable security definer set search_path = '' as $$
  select r.code, r.severity, r.message, r.artifact_kind
    from clm.dossiers d
    join clm.normative_rules r on r.tenant_id = d.tenant_id and r.enabled
         and (r.contract_type_id is null or r.contract_type_id = d.contract_type_id)
    left join clm.artifacts a on a.dossier_id = d.id and a.kind = r.artifact_kind
    left join clm.artifact_versions v on v.id = a.current_version_id
   where d.id = p_dossier
     and case r.kind
           when 'SECCION_REQUERIDA' then not exists (select 1 from jsonb_array_elements(v.content -> 'blocks') b where b ->> 'section' = r.pattern)
           when 'PATRON_PROHIBIDO'  then     exists (select 1 from jsonb_array_elements(v.content -> 'blocks') b where b ->> 'text' ~* r.pattern)
           when 'PATRON_REQUERIDO'  then not exists (select 1 from jsonb_array_elements(v.content -> 'blocks') b where b ->> 'text' ~* r.pattern)
         end
$$;

-- Cada check devuelve NULL si pasa o el motivo del bloqueo. Código desconocido = falla cerrada.
create function app.run_check(d clm.dossiers, p_code text, p jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare v_txt text; v_num numeric; v_n int; i clm.procurement_plan_items;
begin
  case p_code
  when 'PAA_ALINEADO' then
    select it.* into i
      from clm.procurement_plan_items it join clm.procurement_plans pl on pl.id = it.plan_id
     where it.id = d.plan_item_id and pl.status = 'APROBADO' and pl.fiscal_year = d.fiscal_year
       for update of it;                                    -- serializa el consumo del saldo
    if not found then
      return format('No está vinculado a un ítem del PAA aprobado para la vigencia %s', d.fiscal_year);
    end if;
    if not exists (select 1 from clm.organizational_units u where u.id = d.origin_unit_id and i.unit_id = any (u.path)) then
      return 'El ítem del PAA pertenece a otra dependencia';
    end if;
    v_n := coalesce((p ->> 'unspsc_digits')::int, 6);
    if not exists (select 1 from unnest(d.unspsc_codes) a, unnest(i.unspsc_codes) b where left(a, v_n) = left(b, v_n)) then
      return 'Los códigos UNSPSC no corresponden al ítem del PAA';
    end if;
    select coalesce(sum(x.estimated_value), 0) into v_num from clm.dossiers x
     where x.plan_item_id = i.id and x.id <> d.id and x.state <> 'DESISTIDO';
    if v_num + d.estimated_value > i.estimated_value then
      return format('El valor excede el saldo del ítem PAA (disponible %s)', i.estimated_value - v_num);
    end if;

  when 'ARTEFACTOS_REQUERIDOS' then
    select string_agg(k, ', ') into v_txt
      from clm.contract_types ct, unnest(ct.required_artifacts) k
     where ct.id = d.contract_type_id
       and (p -> 'only' is null or k in (select jsonb_array_elements_text(p -> 'only')))
       and not exists (select 1 from clm.artifacts a
                        where a.dossier_id = d.id and a.kind = k and a.current_version_id is not null);
    if v_txt is not null then return 'Faltan artefactos versionados: ' || v_txt; end if;

  when 'AUTORIA_RATIFICADA' then
    select string_agg(a.kind, ', ') into v_txt
      from clm.artifacts a left join clm.artifact_versions v on v.id = a.current_version_id
     where a.dossier_id = d.id and a.stage = 'PRECONTRACTUAL'
       and (v.id is null or v.content_hash <> app.sha256(a.draft::text)
            or not exists (select 1 from clm.authorship_attestations t where t.version_id = v.id));
    if v_txt is not null then return 'Sin versión ratificada o con cambios sin versionar: ' || v_txt; end if;

  when 'VALORES_IA_SOPORTADOS' then
    select string_agg(a.kind || '#' || (b ->> 'id'), ', ') into v_txt
      from clm.artifacts a
      join clm.artifact_versions v on v.id = a.current_version_id
      cross join lateral jsonb_array_elements(v.content -> 'blocks') b
     where a.dossier_id = d.id and b ->> 'type' = 'value'
       and b -> 'provenance' ->> 'origin' in ('AI','AI_EDITED')
       and not exists (select 1 from clm.ai_generations g
                        where g.id = app.try_uuid(b -> 'provenance' ->> 'generation_id') and g.dossier_id = d.id
                          and g.task = 'VALOR_ESTIMADO' and g.decision in ('ACEPTADA','EDITADA'));
    if v_txt is not null then return 'Valores sugeridos por IA sin respaldo documental: ' || v_txt; end if;

  when 'COTIZACIONES_MINIMAS' then
    select count(distinct q.supplier_nit) into v_n from clm.market_quotes q where q.dossier_id = d.id;
    if v_n < coalesce((p ->> 'min')::int, 3) then
      return format('Se requieren %s cotizaciones de proveedores distintos (hay %s)', coalesce((p ->> 'min')::int, 3), v_n);
    end if;

  when 'INTEGRIDAD_MERCADO' then
    if d.market_scanned_at is null
       or exists (select 1 from clm.market_quotes q where q.dossier_id = d.id and q.created_at > d.market_scanned_at) then
      return 'Debe ejecutarse la verificación de integridad sobre las cotizaciones vigentes';
    end if;
    select count(*) into v_n from clm.integrity_findings f
     where f.dossier_id = d.id and f.status = 'ABIERTO' and f.severity <> 'FORMA';
    if v_n > 0 then return format('%s hallazgo(s) de integridad de mercado sin resolver', v_n); end if;

  when 'NORMATIVA_SIN_BLOQUEOS' then
    select string_agg(n.code, ', ') into v_txt from app.normative_findings(d.id) n where n.severity <> 'FORMA';
    if v_txt is not null then return 'Incumple reglas normativas: ' || v_txt; end if;

  when 'CDP_EXPEDIDO' then
    if not exists (select 1 from clm.budget_certificates c where c.dossier_id = d.id and c.kind = 'CDP'
                      and c.status = 'EXPEDIDO' and c.amount >= d.estimated_value) then
      return 'No hay CDP expedido que cubra el valor estimado';
    end if;

  when 'HAY_OBSERVACIONES_ABIERTAS' then
    if not exists (select 1 from clm.observations o where o.dossier_id = d.id and o.status in ('ABIERTA','REABIERTA')) then
      return 'Para devolver o rechazar debe registrar al menos una observación';
    end if;

  when 'OBSERVACIONES_RESPONDIDAS' then
    select count(*) into v_n from clm.observations o where o.dossier_id = d.id and o.status in ('ABIERTA','REABIERTA');
    if v_n > 0 then return format('%s observación(es) sin respuesta', v_n); end if;

  when 'SIN_OBSERVACIONES_BLOQUEANTES' then
    select count(*) into v_n from clm.observations o
     where o.dossier_id = d.id and o.severity <> 'FORMA' and o.status not in ('ACEPTADA','DESISTIDA');
    if v_n > 0 then return format('%s observación(es) bloqueante(s)/sustancial(es) sin cerrar', v_n); end if;

  when 'CONTENIDO_SELLADO' then
    if d.seal_hash is null then return 'El expediente no está sellado'; end if;
    if app.manifest_hash(d.id) <> d.seal_hash then return 'ALERTA: el contenido no coincide con el sello'; end if;

  when 'FIRMA_COMPLETA' then
    if not exists (select 1 from clm.signature_requests s
                     join clm.artifacts a on a.current_version_id = s.artifact_version_id
                    where s.dossier_id = d.id and s.status = 'FIRMADA' and a.kind = 'CONTRATO' and a.sealed_at is not null) then
      return 'El contrato sellado no tiene firma completa';
    end if;

  when 'RP_EXPEDIDO' then
    if not exists (select 1 from clm.budget_certificates c where c.dossier_id = d.id and c.kind = 'RP' and c.status = 'EXPEDIDO') then
      return 'Falta el registro presupuestal';
    end if;

  when 'GARANTIAS_APROBADAS' then
    if (select ct.requires_guarantees from clm.contract_types ct where ct.id = d.contract_type_id)
       and (not exists (select 1 from clm.guarantees g where g.dossier_id = d.id and g.status = 'APROBADA')
            or exists (select 1 from clm.guarantees g where g.dossier_id = d.id and g.status = 'RADICADA')) then
      return 'Garantías pendientes de aprobación';
    end if;

  when 'SUPERVISION_DESIGNADA' then
    if not exists (select 1 from clm.supervision_assignments s where s.dossier_id = d.id and s.revoked_at is null) then
      return 'Falta designar supervisión/interventoría';
    end if;

  when 'REQUIERE_SELECCION' then
    if not (select ct.requires_selection from clm.contract_types ct where ct.id = d.contract_type_id) then
      return 'La tipología es de contratación directa';
    end if;

  when 'CONTRATACION_DIRECTA' then
    if (select ct.requires_selection from clm.contract_types ct where ct.id = d.contract_type_id) then
      return 'La tipología exige proceso de selección';
    end if;

  else
    return 'Compuerta desconocida: ' || p_code;
  end case;
  return null;
end $$;

create function app.evaluate_gates(d clm.dossiers, p_event text, p_hard text[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; v_msg text; v_out jsonb := '[]';
begin
  for r in
    select h as check_code, '{}'::jsonb as params, true as hard from unnest(p_hard) h
    union all
    select g.check_code, g.params, false
      from clm.quality_gate_rules g
     where g.tenant_id = d.tenant_id and g.event = p_event and g.enabled and g.min_rigor <= d.rigor_level
       and (g.contract_type_id is null or g.contract_type_id = d.contract_type_id)
  loop
    v_msg := app.run_check(d, r.check_code, r.params);
    if v_msg is not null then
      v_out := v_out || jsonb_build_object('check', r.check_code, 'hard', r.hard, 'message', v_msg);
    end if;
  end loop;
  return v_out;
end $$;

-- =============================================================================
-- 14. MOTOR DE ESTADOS
-- =============================================================================
create function app.authorize(d clm.dossiers, t ref.fsm_transitions) returns text
language plpgsql security definer set search_path = '' as $$
declare v_uid text := auth.uid(); v_unit uuid; v_role clm.app_role; v_step clm.approval_steps;
begin
  if t.actor_scope = 'SYSTEM' then
    if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
      raise exception 'SOLO_SISTEMA' using errcode = '42501';
    end if;
    return 'SYSTEM';
  end if;
  if v_uid is null then raise exception 'NO_AUTENTICADO' using errcode = '42501'; end if;

  if t.actor_scope = 'ASSIGNED' then
    if d.assigned_reviewer_id is distinct from v_uid
       or not app.user_covers(v_uid, '{REVISOR_JURIDICO}', d.review_unit_id) then
      raise exception 'NO_ES_REVISOR_ASIGNADO' using errcode = '42501';
    end if;
    return 'REVISOR_JURIDICO';
  end if;

  if t.actor_scope = 'STEP' then
    select * into v_step from clm.approval_steps s
     where s.dossier_id = d.id and s.chain_no = d.approval_chain and s.status = 'PENDIENTE'
     order by s.seq limit 1;
    if not found or not app.user_covers(v_uid, array[v_step.role], v_step.unit_id) then
      raise exception 'NO_LE_CORRESPONDE_ESTE_VOBO' using errcode = '42501';
    end if;
    -- Segregación de funciones: quien elabora o ya dio VoBo en la cadena no vuelve a aprobar.
    if v_uid = d.created_by or exists (select 1 from clm.approval_steps s
                                        where s.dossier_id = d.id and s.chain_no = d.approval_chain and s.decided_by = v_uid) then
      raise exception 'CONFLICTO_DE_FUNCIONES' using errcode = '42501';
    end if;
    return v_step.role::text;
  end if;

  v_unit := case t.actor_scope when 'ORIGIN' then d.origin_unit_id else d.review_unit_id end;
  select r into v_role from unnest(t.actor_roles) r where app.user_covers(v_uid, array[r], v_unit) limit 1;
  if v_role is null then
    raise exception 'ROL_NO_AUTORIZADO' using errcode = '42501', detail = array_to_string(t.actor_roles, ',');
  end if;
  return v_role::text;
end $$;

create function app.step_hash(s clm.approval_steps) returns text
language sql immutable set search_path = '' as $$
  select app.sha256(concat_ws('|', s.prev_hash, s.dossier_id, s.chain_no, s.seq, s.role, s.decided_by,
                              s.status, s.manifest_hash, app.ts_utc(s.decided_at)))
$$;

create function app.open_approval_chain(d clm.dossiers, p_manifest text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_steps clm.app_role[]; s clm.approval_steps; i int;
begin
  select r.steps into v_steps from clm.approval_rules r
   where r.tenant_id = d.tenant_id
     and (r.contract_type_id is null or r.contract_type_id = d.contract_type_id)
     and r.min_amount <= d.estimated_value and r.min_rigor <= d.rigor_level
   order by (r.contract_type_id is not null) desc, r.min_amount desc, r.min_rigor desc
   limit 1;
  -- Paso 1: el VoBo del revisor jurídico (queda decidido al aprobar la revisión).
  s.tenant_id := d.tenant_id;  s.dossier_id := d.id;  s.chain_no := d.approval_chain;  s.seq := 1;
  s.role := 'REVISOR_JURIDICO';  s.unit_id := d.review_unit_id;  s.status := 'APROBADO';
  s.manifest_hash := p_manifest;  s.decided_by := auth.uid();  s.decided_at := now();
  s.step_hash := app.step_hash(s);
  insert into clm.approval_steps (tenant_id, dossier_id, chain_no, seq, role, unit_id, status, manifest_hash, decided_by, decided_at, step_hash)
  values (s.tenant_id, s.dossier_id, s.chain_no, s.seq, s.role, s.unit_id, s.status, s.manifest_hash, s.decided_by, s.decided_at, s.step_hash);
  for i in 1 .. coalesce(cardinality(v_steps), 0) loop
    insert into clm.approval_steps (tenant_id, dossier_id, chain_no, seq, role, unit_id, manifest_hash)
    values (d.tenant_id, d.id, d.approval_chain, i + 1, v_steps[i],
            case when v_steps[i] in ('COORDINADOR_CONTRATACION','REVISOR_JURIDICO','JEFE_JURIDICA')
                 then d.review_unit_id else d.origin_unit_id end,
            p_manifest);
  end loop;
end $$;

create function app.render_template(p_body text, p_fields jsonb) returns text
language plpgsql immutable set search_path = '' as $$
declare k text; v text; v_out text := p_body;
begin
  for k in select distinct m[1] from regexp_matches(p_body, '\{\{\s*([a-z0-9_.]+)\s*\}\}', 'g') as m loop
    v := p_fields #>> string_to_array(k, '.');
    if v is null then raise exception 'CAMPO_FALTANTE_EN_PLANTILLA' using detail = k; end if;
    v_out := regexp_replace(v_out, '\{\{\s*' || replace(k, '.', '\.') || '\s*\}\}', replace(v, '\', '\\'), 'g');
  end loop;
  return v_out;
end $$;

-- Campos ya validados por compuertas previas: única fuente para el ensamblado.
create function app.assembly_fields(d clm.dossiers) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'entidad',     jsonb_build_object('nombre', t."nombre", 'nit', t."nit"),
    'dependencia', jsonb_build_object('nombre', u.name),
    'expediente',  jsonb_build_object('numero', d.number, 'objeto', d.object,
                                      'valor_estimado', d.estimated_value, 'plazo_dias', d.estimated_duration_days),
    'cdp',         (select jsonb_build_object('numero', c.number, 'valor', c.amount, 'rubro', c.budget_line)
                      from clm.budget_certificates c
                     where c.dossier_id = d.id and c.kind = 'CDP' and c.status = 'EXPEDIDO'),
    'contrato',    (select jsonb_build_object('numero', k.contract_number, 'contratista', k.contractor_name,
                                              'nit_contratista', k.contractor_nit, 'valor', k.value, 'plazo_dias', k.duration_days)
                      from clm.contracts k where k.dossier_id = d.id),
    'sello',       d.seal_hash))
  from public."Tenant" t, clm.organizational_units u
  where t.id = d.tenant_id and u.id = d.origin_unit_id
$$;

create function app.least_loaded_reviewer(d clm.dossiers) returns text
language sql stable security definer set search_path = '' as $$
  select u.id from clm.users u
   where u.tenant_id = d.tenant_id and u.active and u.id <> d.created_by
     and app.user_covers(u.id, '{REVISOR_JURIDICO}', d.review_unit_id)
   order by (select count(*) from clm.dossiers x
              where x.assigned_reviewer_id = u.id
                and x.state in ('EN_REVISION_JURIDICA','EN_SUBSANACION','EN_CADENA_VOBO')), u.id
   limit 1
$$;

-- Único punto de mutación del estado del expediente.
create function clm.transition(p_dossier uuid, p_event text, p_expected_version int, p_payload jsonb default '{}')
returns clm.dossiers
language plpgsql security definer set search_path = '' as $$
declare
  d          clm.dossiers;
  t          ref.fsm_transitions;
  v_uid      text := auth.uid();
  v_system   boolean := coalesce(auth.jwt() ->> 'role', '') = 'service_role';
  v_role     text;
  v_fail     jsonb;
  v_to       clm.dossier_state;
  v_step     clm.approval_steps;
  v_contract clm.contracts;
  v_tpl      clm.document_templates;
  v_art      uuid;
  v_reviewer text;
  v_text     text;
begin
  select * into d from clm.dossiers x
   where x.id = p_dossier and (v_system or x.tenant_id = app.tenant_id())
   for update;
  if not found or not (v_system or app.can_read_dossier(p_dossier)) then
    raise exception 'EXPEDIENTE_NO_ENCONTRADO' using errcode = 'P0002';
  end if;
  if d.state_version <> p_expected_version then
    raise exception 'CONFLICTO_DE_VERSION' using errcode = '40001', detail = d.state_version::text;
  end if;
  select * into t from ref.fsm_transitions where from_state = d.state and event = p_event;
  if not found then
    raise exception 'TRANSICION_INVALIDA' using detail = format('%s --%s-->', d.state, p_event);
  end if;

  v_role := app.authorize(d, t);                               -- 1. ¿quién?
  v_fail := app.evaluate_gates(d, p_event, t.hard_checks);     -- 2. ¿se cumplen las compuertas?
  if jsonb_array_length(v_fail) > 0 then
    raise exception 'COMPUERTA_BLOQUEADA' using detail = v_fail::text;
  end if;

  perform set_config('app.in_transition', 'on', true);         -- 3. acciones
  v_to := t.to_state;
  case p_event
  when 'SOLICITAR_CDP' then
    insert into clm.budget_certificates (tenant_id, dossier_id, kind, amount, status)
    values (d.tenant_id, d.id, 'CDP', d.estimated_value, 'SOLICITADO');

  when 'EXPEDIR_CDP' then
    if app.req(p_payload, 'amount')::numeric < d.estimated_value then
      raise exception 'CDP_INSUFICIENTE';
    end if;
    update clm.budget_certificates
       set status = 'EXPEDIDO', number = app.req(p_payload, 'number'), budget_line = app.req(p_payload, 'budget_line'),
           amount = (p_payload ->> 'amount')::numeric, issued_by = v_uid, issued_at = now()
     where dossier_id = d.id and kind = 'CDP' and status = 'SOLICITADO';
    d.review_unit_id := app.resolve_review_unit(d.tenant_id, d.origin_unit_id, d.contract_type_id, d.estimated_value);
    if d.review_unit_id is null then raise exception 'SIN_UNIDAD_REVISORA'; end if;

  when 'RECHAZAR_CDP' then
    perform app.req(p_payload, 'reason');
    update clm.budget_certificates set status = 'ANULADO'
     where dossier_id = d.id and kind = 'CDP' and status = 'SOLICITADO';

  when 'ASIGNAR_REVISOR', 'REASIGNAR_REVISOR' then
    v_reviewer := coalesce(nullif(p_payload ->> 'reviewer_id', ''), app.least_loaded_reviewer(d));
    if v_reviewer is null or not app.user_covers(v_reviewer, '{REVISOR_JURIDICO}', d.review_unit_id) then
      raise exception 'REVISOR_NO_COMPETENTE';
    end if;
    if v_reviewer = d.created_by then raise exception 'CONFLICTO_DE_FUNCIONES'; end if;
    d.assigned_reviewer_id := v_reviewer;

  when 'DEVOLVER' then
    d.review_round := d.review_round + 1;

  when 'APROBAR_REVISION' then
    d.approval_chain := d.approval_chain + 1;
    perform app.open_approval_chain(d, app.manifest_hash(d.id));
    if not exists (select 1 from clm.approval_steps s
                    where s.dossier_id = d.id and s.chain_no = d.approval_chain and s.status = 'PENDIENTE') then
      v_to := 'APROBADO';
    end if;

  when 'VOBO', 'RECHAZAR_VOBO' then
    select * into v_step from clm.approval_steps s
     where s.dossier_id = d.id and s.chain_no = d.approval_chain and s.status = 'PENDIENTE'
     order by s.seq limit 1 for update;
    if app.manifest_hash(d.id) <> v_step.manifest_hash then raise exception 'MANIFIESTO_ALTERADO'; end if;
    select s.step_hash into v_step.prev_hash from clm.approval_steps s
     where s.dossier_id = d.id and s.chain_no = d.approval_chain and s.seq = v_step.seq - 1;
    v_step.status     := case p_event when 'VOBO' then 'APROBADO' else 'RECHAZADO' end;
    v_step.decided_by := v_uid;
    v_step.decided_at := now();
    v_step.comment    := p_payload ->> 'comment';
    v_step.step_hash  := app.step_hash(v_step);
    update clm.approval_steps
       set status = v_step.status, decided_by = v_step.decided_by, decided_at = v_step.decided_at,
           comment = v_step.comment, prev_hash = v_step.prev_hash, step_hash = v_step.step_hash
     where id = v_step.id;
    if p_event = 'RECHAZAR_VOBO' then
      update clm.approval_steps set status = 'ANULADO'
       where dossier_id = d.id and chain_no = d.approval_chain and status = 'PENDIENTE';
      d.review_round := d.review_round + 1;
    elsif not exists (select 1 from clm.approval_steps s
                       where s.dossier_id = d.id and s.chain_no = d.approval_chain and s.status = 'PENDIENTE') then
      v_to := 'APROBADO';
    else
      v_to := 'EN_CADENA_VOBO';
    end if;

  when 'ADJUDICAR' then
    insert into clm.contracts (tenant_id, dossier_id, contract_number, contractor_nit, contractor_name, value, duration_days)
    values (d.tenant_id, d.id, app.req(p_payload, 'contract_number'), app.req(p_payload, 'contractor_nit'),
            app.req(p_payload, 'contractor_name'), app.req(p_payload, 'value')::numeric,
            coalesce((p_payload ->> 'duration_days')::int, d.estimated_duration_days))
    returning * into v_contract;
    if v_contract.value > (select max(c.amount) from clm.budget_certificates c
                            where c.dossier_id = d.id and c.kind = 'CDP' and c.status = 'EXPEDIDO') then
      raise exception 'VALOR_SUPERA_CDP';
    end if;

  when 'ENSAMBLAR_CONTRATO' then
    select * into v_tpl from clm.document_templates x
     where x.tenant_id = d.tenant_id and x.contract_type_id = d.contract_type_id
       and x.artifact_kind = 'CONTRATO' and x.active
     order by x.version desc limit 1;
    if not found then raise exception 'SIN_PLANTILLA_DE_CONTRATO'; end if;
    v_text := app.render_template(v_tpl.body, app.assembly_fields(d));
    insert into clm.artifacts (tenant_id, dossier_id, kind, stage, title, draft)
    values (d.tenant_id, d.id, 'CONTRATO', 'CONTRACTUAL', 'Contrato',
            jsonb_build_object('blocks', (
              select jsonb_agg(jsonb_build_object('id', 'p' || n, 'type', 'paragraph', 'text', trim(para),
                       'provenance', jsonb_build_object('origin', 'TEMPLATE', 'template_id', v_tpl.id, 'template_version', v_tpl.version))
                     order by n)
                from regexp_split_to_table(v_text, '\n\s*\n') with ordinality as x(para, n)
               where trim(para) <> '')))
    on conflict (tenant_id, dossier_id, kind) do update set draft = excluded.draft, sealed_at = null, sealed_hash = null
    returning id into v_art;
    insert into clm.artifact_versions (tenant_id, dossier_id, artifact_id, major, minor, content, content_hash, created_by)
    values (d.tenant_id, d.id, v_art, 0, 0, '{}', '', coalesce(v_uid, d.created_by));   -- el trigger completa el snapshot
    update clm.artifacts a set sealed_at = now(), sealed_hash = v.content_hash
      from clm.artifact_versions v where a.id = v_art and v.id = a.current_version_id;

  when 'PERFECCIONAR' then
    update clm.contracts
       set signed_at = coalesce((p_payload ->> 'signed_at')::timestamptz, now()),
           signature_request_id = app.req(p_payload, 'signature_request_id')::uuid
     where dossier_id = d.id;

  when 'EXPEDIR_RP' then
    select * into v_contract from clm.contracts where dossier_id = d.id;
    if app.req(p_payload, 'amount')::numeric <> v_contract.value then
      raise exception 'RP_NO_COINCIDE_CON_CONTRATO';
    end if;
    insert into clm.budget_certificates (tenant_id, dossier_id, kind, number, budget_line, amount, status, issued_by, issued_at)
    values (d.tenant_id, d.id, 'RP', app.req(p_payload, 'number'), app.req(p_payload, 'budget_line'),
            v_contract.value, 'EXPEDIDO', v_uid, now());

  when 'REGISTRAR_GARANTIA' then
    insert into clm.guarantees (tenant_id, dossier_id, contract_id, coverage, insurer, policy_number,
                                   insured_amount, valid_from, valid_to, document_path)
    select d.tenant_id, d.id, c.id, app.req(p_payload, 'coverage'), app.req(p_payload, 'insurer'),
           app.req(p_payload, 'policy_number'), app.req(p_payload, 'insured_amount')::numeric,
           app.req(p_payload, 'valid_from')::date, app.req(p_payload, 'valid_to')::date, p_payload ->> 'document_path'
      from clm.contracts c where c.dossier_id = d.id;

  when 'APROBAR_GARANTIA', 'RECHAZAR_GARANTIA' then
    update clm.guarantees
       set status = case p_event when 'APROBAR_GARANTIA' then 'APROBADA' else 'RECHAZADA' end,
           reviewed_by = v_uid, reviewed_at = now()
     where id = app.req(p_payload, 'guarantee_id')::uuid and dossier_id = d.id and status = 'RADICADA';
    if not found then raise exception 'GARANTIA_NO_PENDIENTE'; end if;

  when 'DESIGNAR_SUPERVISION' then
    update clm.supervision_assignments set revoked_at = now() where dossier_id = d.id and revoked_at is null;
    insert into clm.supervision_assignments (tenant_id, dossier_id, contract_id, kind, supervisor_user_id,
                                                external_name, designation_doc_path, designated_by)
    select d.tenant_id, d.id, c.id, app.req(p_payload, 'kind'), nullif(p_payload ->> 'supervisor_user_id', ''),
           p_payload ->> 'external_name', p_payload ->> 'designation_doc_path', v_uid
      from clm.contracts c where c.dossier_id = d.id;

  when 'HABILITAR_EJECUCION' then
    update clm.contracts
       set execution_enabled_at = now(), start_date = coalesce((p_payload ->> 'start_date')::date, current_date)
     where dossier_id = d.id;

  when 'DESISTIR' then
    perform app.req(p_payload, 'reason');
    update clm.budget_certificates set status = 'ANULADO'
     where dossier_id = d.id and status = 'SOLICITADO';

  else
    null;  -- SOLICITAR/REENVIAR/INICIAR_SELECCION: solo cambian estado (las compuertas hacen el trabajo)
  end case;

  update clm.dossiers
     set state = v_to, state_version = state_version + 1,
         review_unit_id = d.review_unit_id, assigned_reviewer_id = d.assigned_reviewer_id,
         review_round = d.review_round, approval_chain = d.approval_chain, updated_at = now()
   where id = d.id
  returning * into d;

  if v_to = 'APROBADO' and d.seal_hash is null then          -- 4. sello de contenido
    update clm.artifacts set sealed_at = now(), sealed_hash = app.manifest_hash(d.id)
     where dossier_id = d.id and stage = 'PRECONTRACTUAL';
    update clm.dossiers set seal_hash = app.manifest_hash(d.id), sealed_at = now()
     where id = d.id returning * into d;
  end if;

  perform set_config('app.in_transition', 'off', true);

  perform app.audit(d.tenant_id, d.origin_unit_id, d.id, 'TRANSICION:' || p_event, 'dossiers', d.id,
                    coalesce(d.seal_hash, app.manifest_hash(d.id)),
                    jsonb_build_object('from', t.from_state, 'to', v_to, 'state_version', d.state_version, 'payload', p_payload),
                    v_role);
  return d;
end $$;

-- Checklist previo para la UI (no muta nada).
create function clm.preview_gates(p_dossier uuid, p_event text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d clm.dossiers; t ref.fsm_transitions;
begin
  select * into d from clm.dossiers where id = p_dossier and tenant_id = app.tenant_id();
  if not found or not app.can_read_dossier(p_dossier) then raise exception 'EXPEDIENTE_NO_ENCONTRADO'; end if;
  select * into t from ref.fsm_transitions where from_state = d.state and event = p_event;
  if not found then return jsonb_build_array(jsonb_build_object('check', 'TRANSICION', 'hard', true, 'message', 'Evento no válido en ' || d.state)); end if;
  return app.evaluate_gates(d, p_event, t.hard_checks);
end $$;

create function clm.normative_report(p_dossier uuid)
returns table (code text, severity clm.obs_severity, message text, artifact_kind text)
language sql stable security definer set search_path = '' as $$
  select n.* from app.normative_findings(p_dossier) n where app.can_read_dossier(p_dossier)
$$;

-- Diff estructurado por bloque (ids estables). El diff palabra a palabra lo hace el cliente.
create function clm.diff_versions(p_from uuid, p_to uuid)
returns table (block_id text, change text, before jsonb, after jsonb)
language sql stable security invoker set search_path = '' as $$
  with a as (select b ->> 'id' as id, b from clm.artifact_versions v, jsonb_array_elements(v.content -> 'blocks') b where v.id = p_from),
       z as (select b ->> 'id' as id, b from clm.artifact_versions v, jsonb_array_elements(v.content -> 'blocks') b where v.id = p_to)
  select coalesce(a.id, z.id),
         case when a.id is null then 'ADDED' when z.id is null then 'REMOVED'
              when a.b = z.b then 'UNCHANGED' else 'MODIFIED' end,
         a.b, z.b
    from a full join z on a.id = z.id
  union all
  select '$metadata', case when x.metadata = y.metadata then 'UNCHANGED' else 'MODIFIED' end, x.metadata, y.metadata
    from clm.artifact_versions x, clm.artifact_versions y
   where x.id = p_from and y.id = p_to
$$;

create function clm.verify_audit_chain() returns bigint
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_tenant_role('{AUDITOR,ADMIN_ENTIDAD}') then raise exception 'SIN_PERMISO' using errcode = '42501'; end if;
  return app.verify_audit_chain(app.tenant_id());
end $$;

-- =============================================================================
-- 16. INTEGRIDAD DE MERCADO
-- =============================================================================
create function clm.scan_market_integrity(p_dossier uuid) returns setof clm.integrity_findings
language plpgsql security definer set search_path = '' as $$
declare d clm.dossiers;
begin
  select * into d from clm.dossiers where id = p_dossier and tenant_id = app.tenant_id();
  if not found or not app.can_edit_dossier(p_dossier) then raise exception 'SIN_PERMISO' using errcode = '42501'; end if;

  update clm.integrity_findings set status = 'SUPERADO' where dossier_id = d.id and status = 'ABIERTO';

  with q as (select distinct supplier_nit as nit from clm.market_quotes where dossier_id = d.id)
  insert into clm.integrity_findings (tenant_id, dossier_id, kind, severity, subjects, evidence)
  -- 1. Vínculos cruzados entre cotizantes (representantes, socios, domicilio, teléfono)
  select d.tenant_id, d.id, 'VINCULO_CRUZADO', 'BLOQUEANTE'::clm.obs_severity, array[ra.nit, rb.nit],
         jsonb_build_object('representante_comun', ra.legal_rep_hashes && rb.legal_rep_hashes,
                            'socio_comun',         ra.shareholder_hashes && rb.shareholder_hashes,
                            'mismo_domicilio',     ra.address_hash = rb.address_hash,
                            'mismo_telefono',      ra.phone_hash = rb.phone_hash)
    from q a join q b on a.nit < b.nit
    join ref.company_registry ra on ra.nit = a.nit
    join ref.company_registry rb on rb.nit = b.nit
   where ra.legal_rep_hashes && rb.legal_rep_hashes or ra.shareholder_hashes && rb.shareholder_hashes
      or ra.address_hash = rb.address_hash or ra.phone_hash = rb.phone_hash
  union all
  -- 2. Sanciones / inhabilidades vigentes
  select d.tenant_id, d.id, 'INHABILIDAD', 'BLOQUEANTE', array[s.nit],
         jsonb_build_object('fuente', s.source, 'tipo', s.kind, 'vigente_hasta', s.valid_until, 'detalle', s.detail)
    from q join ref.sanctions s on s.nit = q.nit
   where s.valid_until is null or s.valid_until >= current_date
  union all
  -- 3. Cotizante sin registro mercantil activo
  select d.tenant_id, d.id, 'SIN_REGISTRO', 'SUSTANCIAL', array[q.nit], jsonb_build_object('estado', r.status)
    from q left join ref.company_registry r on r.nit = q.nit
   where r.nit is null or r.status <> 'ACTIVA'
  union all
  -- 4. Actividad económica (CIIU) sin relación con la clase UNSPSC del objeto (solo si hay mapeo)
  select d.tenant_id, d.id, 'CIIU_INCONSISTENTE', 'SUSTANCIAL', array[r.nit],
         jsonb_build_object('ciiu', r.ciiu_codes, 'unspsc', d.unspsc_codes)
    from q join ref.company_registry r on r.nit = q.nit
   where exists (select 1 from ref.unspsc_ciiu m where m.unspsc_class in (select left(c, 6) from unnest(d.unspsc_codes) c))
     and not exists (select 1 from ref.unspsc_ciiu m
                      where m.unspsc_class in (select left(c, 6) from unnest(d.unspsc_codes) c)
                        and m.ciiu = any (r.ciiu_codes))
  union all
  -- 5. Cotización atípica frente a la mediana del propio estudio (>50%)
  select d.tenant_id, d.id, 'COTIZACION_ATIPICA', 'FORMA', array[x.supplier_nit],
         jsonb_build_object('valor', x.amount, 'mediana', x.med)
    from (select mq.supplier_nit, mq.amount,
                 (select percentile_cont(0.5) within group (order by m2.amount)
                    from clm.market_quotes m2 where m2.dossier_id = d.id) as med
            from clm.market_quotes mq where mq.dossier_id = d.id) x
   where x.med > 0 and abs(x.amount - x.med) / x.med > 0.5;

  update clm.dossiers set market_scanned_at = clock_timestamp() where id = d.id;
  return query select * from clm.integrity_findings f where f.dossier_id = d.id and f.status = 'ABIERTO';
end $$;

-- =============================================================================
-- 17. RAG: recuperación con aislamiento por tenant
-- =============================================================================
-- SECURITY INVOKER: la RLS de tenant_chunks aplica (tenant + árbol de dependencias).
-- El filtro explícito por tenant es redundante a propósito (defensa en profundidad).
create function clm.match_context(p_query extensions.vector, p_k int default 8, p_unspsc text[] default null)
returns table (source text, ref_id text, content text, similarity double precision)
language sql stable security invoker set search_path = '' as $$
  (select 'tenant', c.id::text, c.content, 1 - (c.embedding operator(extensions.<=>) p_query)
     from clm.tenant_chunks c
    where c.tenant_id = app.tenant_id()
    order by c.embedding operator(extensions.<=>) p_query
    limit p_k)
  union all
  (select 'public', c.id::text, c.content, 1 - (c.embedding operator(extensions.<=>) p_query)
     from ref.public_chunks c
    where p_unspsc is null or c.unspsc_segment in (select left(x, 2) from unnest(p_unspsc) x)
    order by c.embedding operator(extensions.<=>) p_query
    limit p_k)
$$;

-- =============================================================================
-- 18. RLS
-- =============================================================================
alter table clm.tenants                enable row level security;
alter table clm.users                  enable row level security;
alter table clm.dossiers               enable row level security;
alter table clm.procurement_plans      enable row level security;
alter table clm.procurement_plan_items enable row level security;
alter table clm.audit_events           enable row level security;

create policy tenants_read on clm.tenants for select to authenticated using (id = app.tenant_id());
create policy users_read   on clm.users   for select to authenticated using (tenant_id = app.tenant_id());

-- Configuración: lectura para todo el tenant, escritura solo ADMIN_ENTIDAD con alcance TENANT.
do $$
declare t text;
begin
  foreach t in array array['organizational_units','user_memberships','contract_types','review_delegations',
                           'approval_rules','quality_gate_rules','normative_rules','document_templates'] loop
    execute format('alter table clm.%I enable row level security', t);
    execute format('create policy %I on clm.%I for select to authenticated using (tenant_id = app.tenant_id())', t || '_read', t);
    execute format($p$create policy %I on clm.%I for all to authenticated
                      using (tenant_id = app.tenant_id() and app.has_tenant_role('{ADMIN_ENTIDAD}'))
                      with check (tenant_id = app.tenant_id() and app.has_tenant_role('{ADMIN_ENTIDAD}'))$p$, t || '_admin', t);
  end loop;
  -- Todo lo que cuelga de un expediente se ve si se ve el expediente.
  foreach t in array array['artifacts','artifact_versions','authorship_attestations','observations','observation_responses',
                           'approval_steps','budget_certificates','contracts','guarantees','supervision_assignments',
                           'contract_modifications','signature_requests','market_quotes','integrity_findings',
                           'ai_generations','tenant_chunks'] loop
    execute format('alter table clm.%I enable row level security', t);
    execute format('create policy %I on clm.%I for select to authenticated using (tenant_id = app.tenant_id() and app.can_read_dossier(dossier_id))', t || '_read', t);
  end loop;
end $$;

-- PAA: oficina de planeación con alcance TENANT; ítems solo mientras el plan esté en BORRADOR.
create policy plans_read  on clm.procurement_plans for select to authenticated using (tenant_id = app.tenant_id());
create policy plans_write on clm.procurement_plans for all to authenticated
  using (tenant_id = app.tenant_id() and app.has_tenant_role('{PLANEACION}') and status = 'BORRADOR')
  with check (tenant_id = app.tenant_id() and app.has_tenant_role('{PLANEACION}'));
create policy plan_items_read  on clm.procurement_plan_items for select to authenticated using (tenant_id = app.tenant_id());
create policy plan_items_write on clm.procurement_plan_items for all to authenticated
  using (tenant_id = app.tenant_id() and app.has_tenant_role('{PLANEACION}')
         and exists (select 1 from clm.procurement_plans p where p.id = plan_id and p.status = 'BORRADOR'))
  with check (tenant_id = app.tenant_id() and app.has_tenant_role('{PLANEACION}')
         and exists (select 1 from clm.procurement_plans p where p.id = plan_id and p.status = 'BORRADOR'));

-- Expediente
create policy dossiers_read   on clm.dossiers for select to authenticated
  using (tenant_id = app.tenant_id() and app.can_read_dossier_row(dossiers));
create policy dossiers_create on clm.dossiers for insert to authenticated
  with check (tenant_id = app.tenant_id() and app.covers('{ELABORADOR,JEFE_AREA}', origin_unit_id));
create policy dossiers_edit   on clm.dossiers for update to authenticated
  using (app.can_edit_dossier(id)) with check (app.can_edit_dossier(id));

-- Área técnica (solo BORRADOR / EN_SUBSANACION vía can_edit_dossier)
create policy artifacts_create on clm.artifacts for insert to authenticated
  with check (tenant_id = app.tenant_id() and app.can_edit_dossier(dossier_id));
create policy artifacts_edit on clm.artifacts for update to authenticated
  using (app.can_edit_dossier(dossier_id) and sealed_at is null)
  with check (app.can_edit_dossier(dossier_id) and sealed_at is null);
create policy versions_create on clm.artifact_versions for insert to authenticated
  with check (tenant_id = app.tenant_id() and app.can_edit_dossier(dossier_id));
create policy attestations_create on clm.authorship_attestations for insert to authenticated
  with check (tenant_id = app.tenant_id() and user_id = (select auth.uid()) and app.can_edit_dossier(dossier_id));
create policy responses_create on clm.observation_responses for insert to authenticated
  with check (tenant_id = app.tenant_id() and app.can_edit_dossier(dossier_id));
create policy quotes_create on clm.market_quotes for insert to authenticated
  with check (tenant_id = app.tenant_id() and app.can_edit_dossier(dossier_id));
create policy quotes_delete on clm.market_quotes for delete to authenticated
  using (app.can_edit_dossier(dossier_id));
create policy ai_create on clm.ai_generations for insert to authenticated
  with check (tenant_id = app.tenant_id() and app.can_edit_dossier(dossier_id));
create policy ai_decide on clm.ai_generations for update to authenticated
  using (app.can_edit_dossier(dossier_id)) with check (app.can_edit_dossier(dossier_id));
create policy findings_resolve on clm.integrity_findings for update to authenticated
  using (tenant_id = app.tenant_id() and exists (
           select 1 from clm.dossiers d where d.id = dossier_id
              and d.state in ('BORRADOR','EN_SUBSANACION') and app.covers('{JEFE_AREA}', d.origin_unit_id)))
  with check (status in ('DESCARTADO_JUSTIFICADO','CONFIRMADO'));

-- Jurídica: observa solo el revisor asignado (o el VoBo en turno); el elaborador queda fuera.
create policy observations_create on clm.observations for insert to authenticated
  with check (tenant_id = app.tenant_id() and app.can_observe(dossier_id));
create policy observations_close on clm.observations for update to authenticated
  using (tenant_id = app.tenant_id() and exists (
           select 1 from clm.dossiers d where d.id = dossier_id
              and d.state = 'EN_REVISION_JURIDICA' and d.assigned_reviewer_id = (select auth.uid())))
  with check (status in ('ACEPTADA','REABIERTA','DESISTIDA'));
create policy signatures_create on clm.signature_requests for insert to authenticated
  with check (tenant_id = app.tenant_id() and exists (
           select 1 from clm.dossiers d where d.id = dossier_id and d.state = 'ADJUDICADO'
              and app.covers('{COORDINADOR_CONTRATACION,JEFE_JURIDICA}', d.review_unit_id)));
create policy modifications_create on clm.contract_modifications for insert to authenticated
  with check (tenant_id = app.tenant_id() and exists (
           select 1 from clm.dossiers d where d.id = dossier_id and d.state = 'EJECUCION_HABILITADA'
              and app.covers('{JEFE_JURIDICA}', d.review_unit_id)));

create policy audit_read on clm.audit_events for select to authenticated
  using (tenant_id = app.tenant_id()
         and (app.has_tenant_role('{AUDITOR,ADMIN_ENTIDAD}') or (dossier_id is not null and app.can_read_dossier(dossier_id))));

-- =============================================================================
-- 19. PRIVILEGIOS (columna a columna: lo que no se concede, no se toca)
-- =============================================================================
revoke all on all tables    in schema clm, app, ref from authenticated;
revoke all on all functions in schema clm, app       from public, authenticated;
grant select on all tables in schema clm to authenticated;
grant select on all tables in schema ref    to authenticated;

grant insert, update, delete on clm.organizational_units, clm.user_memberships, clm.contract_types,
  clm.review_delegations, clm.approval_rules, clm.quality_gate_rules, clm.normative_rules,
  clm.document_templates, clm.procurement_plans, clm.procurement_plan_items to authenticated;
grant insert (tenant_id, origin_unit_id, contract_type_id, plan_item_id, fiscal_year, object,
              estimated_value, estimated_duration_days, unspsc_codes) on clm.dossiers to authenticated;
grant update (plan_item_id, object, estimated_value, estimated_duration_days, unspsc_codes) on clm.dossiers to authenticated;
grant insert (tenant_id, dossier_id, kind, title, draft) on clm.artifacts to authenticated;
grant update (title, draft)                              on clm.artifacts to authenticated;
grant insert (artifact_id, metadata, storage_path)       on clm.artifact_versions to authenticated;
grant insert (version_id)                                on clm.authorship_attestations to authenticated;
grant insert (dossier_id, artifact_id, block_id, severity, category, body) on clm.observations to authenticated;
grant update (status)                                    on clm.observations to authenticated;
grant insert (observation_id, resolution, justification, corrected_version_id) on clm.observation_responses to authenticated;
grant insert (tenant_id, dossier_id, supplier_nit, supplier_name, amount, quote_date, document_path) on clm.market_quotes to authenticated;
grant delete                                             on clm.market_quotes to authenticated;
grant update (status, justification)                     on clm.integrity_findings to authenticated;
grant insert (tenant_id, dossier_id, artifact_id, block_id, task, model, prompt_version, prompt_hash, citations, output)
                                                         on clm.ai_generations to authenticated;
grant update (decision)                                  on clm.ai_generations to authenticated;
grant insert (tenant_id, dossier_id, artifact_version_id, provider, pdf_sha256, signers) on clm.signature_requests to authenticated;
grant insert (tenant_id, dossier_id, contract_id, kind, value_delta, days_delta, signed_at) on clm.contract_modifications to authenticated;

-- Funciones que la RLS y los triggers invocan con el rol del usuario.
grant execute on function app.tenant_id(), app.try_uuid(text), app.sha256(text), app.ts_utc(timestamptz),
  app.in_transition(), app.user_covers(text, clm.app_role[], uuid), app.covers(clm.app_role[], uuid),
  app.has_tenant_role(clm.app_role[]), app.can_read_dossier(uuid), app.can_read_dossier_row(clm.dossiers), app.can_edit_dossier(uuid),
  app.can_observe(uuid) to authenticated;
-- API pública (PostgREST /rpc)
grant execute on function clm.transition(uuid, text, int, jsonb), clm.preview_gates(uuid, text),
  clm.normative_report(uuid), clm.diff_versions(uuid, uuid), clm.verify_audit_chain(),
  clm.scan_market_integrity(uuid), clm.match_context(extensions.vector, int, text[]) to authenticated;

-- =============================================================================
-- 21. CATÁLOGOS GLOBALES
-- =============================================================================
insert into ref.gate_checks (code, description) values
  ('PAA_ALINEADO',                  'Ítem del PAA aprobado, misma dependencia (o ancestro), UNSPSC compatible y saldo suficiente'),
  ('ARTEFACTOS_REQUERIDOS',         'Todos los artefactos exigidos por la tipología tienen versión'),
  ('AUTORIA_RATIFICADA',            'Versión vigente ratificada por el elaborador y sin cambios sin versionar'),
  ('VALORES_IA_SOPORTADOS',         'Todo valor sugerido por IA cita benchmarks o contratos indexados'),
  ('COTIZACIONES_MINIMAS',          'Número mínimo de cotizaciones de proveedores distintos (param: min)'),
  ('INTEGRIDAD_MERCADO',            'Verificación de cotizantes ejecutada y sin hallazgos abiertos'),
  ('NORMATIVA_SIN_BLOQUEOS',        'Sin incumplimientos de reglas normativas bloqueantes/sustanciales'),
  ('CDP_EXPEDIDO',                  'CDP expedido por valor ≥ estimado'),
  ('HAY_OBSERVACIONES_ABIERTAS',    'Existe al menos una observación pendiente'),
  ('OBSERVACIONES_RESPONDIDAS',     'Todas las observaciones tienen respuesta'),
  ('SIN_OBSERVACIONES_BLOQUEANTES', 'Ninguna observación bloqueante/sustancial sin cerrar'),
  ('CONTENIDO_SELLADO',             'Sello vigente y verificado contra el manifiesto'),
  ('FIRMA_COMPLETA',                'Contrato sellado con firma completa'),
  ('RP_EXPEDIDO',                   'Registro presupuestal expedido'),
  ('GARANTIAS_APROBADAS',           'Garantías aprobadas (si la tipología las exige)'),
  ('SUPERVISION_DESIGNADA',         'Supervisión o interventoría designada'),
  ('REQUIERE_SELECCION',            'La tipología exige proceso de selección'),
  ('CONTRATACION_DIRECTA',          'La tipología es de contratación directa');

insert into ref.fsm_transitions (from_state, event, to_state, actor_roles, actor_scope, hard_checks) values
  ('BORRADOR',             'SOLICITAR_CDP',      'PENDIENTE_CDP',        '{ELABORADOR,JEFE_AREA}', 'ORIGIN', '{PAA_ALINEADO,AUTORIA_RATIFICADA,VALORES_IA_SOPORTADOS}'),
  ('PENDIENTE_CDP',        'EXPEDIR_CDP',        'EN_COLA_JURIDICA',     '{PRESUPUESTO}',          'ORIGIN', '{PAA_ALINEADO}'),
  ('PENDIENTE_CDP',        'RECHAZAR_CDP',       'BORRADOR',             '{PRESUPUESTO}',          'ORIGIN', '{}'),
  ('EN_COLA_JURIDICA',     'ASIGNAR_REVISOR',    'EN_REVISION_JURIDICA', '{COORDINADOR_CONTRATACION,JEFE_JURIDICA}', 'REVIEW', '{}'),
  ('EN_REVISION_JURIDICA', 'REASIGNAR_REVISOR',  'EN_REVISION_JURIDICA', '{COORDINADOR_CONTRATACION,JEFE_JURIDICA}', 'REVIEW', '{}'),
  ('EN_SUBSANACION',       'REASIGNAR_REVISOR',  'EN_SUBSANACION',       '{COORDINADOR_CONTRATACION,JEFE_JURIDICA}', 'REVIEW', '{}'),
  ('EN_REVISION_JURIDICA', 'DEVOLVER',           'EN_SUBSANACION',       '{}', 'ASSIGNED', '{HAY_OBSERVACIONES_ABIERTAS}'),
  ('EN_SUBSANACION',       'REENVIAR',           'EN_REVISION_JURIDICA', '{ELABORADOR,JEFE_AREA}', 'ORIGIN', '{OBSERVACIONES_RESPONDIDAS,AUTORIA_RATIFICADA,VALORES_IA_SOPORTADOS,PAA_ALINEADO}'),
  ('EN_REVISION_JURIDICA', 'APROBAR_REVISION',   'EN_CADENA_VOBO',       '{}', 'ASSIGNED', '{SIN_OBSERVACIONES_BLOQUEANTES,ARTEFACTOS_REQUERIDOS,AUTORIA_RATIFICADA,CDP_EXPEDIDO}'),
  ('EN_CADENA_VOBO',       'VOBO',               null,                   '{}', 'STEP',     '{}'),
  ('EN_CADENA_VOBO',       'RECHAZAR_VOBO',      'EN_SUBSANACION',       '{}', 'STEP',     '{HAY_OBSERVACIONES_ABIERTAS}'),
  ('APROBADO',             'INICIAR_SELECCION',  'EN_SELECCION',         '{COORDINADOR_CONTRATACION,JEFE_JURIDICA}', 'REVIEW', '{CONTENIDO_SELLADO,REQUIERE_SELECCION}'),
  ('APROBADO',             'ADJUDICAR',          'ADJUDICADO',           '{ORDENADOR_GASTO}', 'ORIGIN', '{CONTENIDO_SELLADO,CONTRATACION_DIRECTA}'),
  ('EN_SELECCION',         'ADJUDICAR',          'ADJUDICADO',           '{ORDENADOR_GASTO}', 'ORIGIN', '{CONTENIDO_SELLADO}'),
  ('ADJUDICADO',           'ENSAMBLAR_CONTRATO', 'ADJUDICADO',           '{COORDINADOR_CONTRATACION,JEFE_JURIDICA}', 'REVIEW', '{CONTENIDO_SELLADO}'),
  ('ADJUDICADO',           'PERFECCIONAR',       'PERFECCIONADO',        '{}', 'SYSTEM',   '{CONTENIDO_SELLADO,FIRMA_COMPLETA}'),
  ('PERFECCIONADO',        'EXPEDIR_RP',         'PERFECCIONADO',        '{PRESUPUESTO}', 'ORIGIN', '{}'),
  ('PERFECCIONADO',        'REGISTRAR_GARANTIA', 'PERFECCIONADO',        '{COORDINADOR_CONTRATACION,REVISOR_JURIDICO}', 'REVIEW', '{}'),
  ('PERFECCIONADO',        'APROBAR_GARANTIA',   'PERFECCIONADO',        '{JEFE_JURIDICA,COORDINADOR_CONTRATACION}', 'REVIEW', '{}'),
  ('PERFECCIONADO',        'RECHAZAR_GARANTIA',  'PERFECCIONADO',        '{JEFE_JURIDICA,COORDINADOR_CONTRATACION}', 'REVIEW', '{}'),
  ('PERFECCIONADO',        'DESIGNAR_SUPERVISION','PERFECCIONADO',       '{ORDENADOR_GASTO}', 'ORIGIN', '{}'),
  ('PERFECCIONADO',        'HABILITAR_EJECUCION','EJECUCION_HABILITADA', '{ORDENADOR_GASTO}', 'ORIGIN', '{RP_EXPEDIDO,GARANTIAS_APROBADAS,SUPERVISION_DESIGNADA}');

insert into ref.fsm_transitions (from_state, event, to_state, actor_roles, actor_scope)
select s, 'DESISTIR', 'DESISTIDO', '{ORDENADOR_GASTO,JEFE_AREA}', 'ORIGIN'
  from unnest('{BORRADOR,PENDIENTE_CDP,EN_COLA_JURIDICA,EN_REVISION_JURIDICA,EN_SUBSANACION,EN_CADENA_VOBO,APROBADO,EN_SELECCION,ADJUDICADO}'::clm.dossier_state[]) s;

-- Reglas por defecto de un tenant nuevo (el rigor sube las exigencias).
create function app.bootstrap_tenant(p_tenant text) returns void
language sql security definer set search_path = '' as $$
  insert into clm.quality_gate_rules (tenant_id, event, check_code, min_rigor, params) values
    (p_tenant, 'SOLICITAR_CDP', 'ARTEFACTOS_REQUERIDOS',  1, '{"only": ["ESTUDIO_PREVIO"]}'),
    (p_tenant, 'SOLICITAR_CDP', 'NORMATIVA_SIN_BLOQUEOS', 1, '{}'),
    (p_tenant, 'SOLICITAR_CDP', 'COTIZACIONES_MINIMAS',   2, '{"min": 2}'),
    (p_tenant, 'SOLICITAR_CDP', 'INTEGRIDAD_MERCADO',     2, '{}'),
    (p_tenant, 'SOLICITAR_CDP', 'COTIZACIONES_MINIMAS',   3, '{"min": 3}'),
    (p_tenant, 'REENVIAR',      'NORMATIVA_SIN_BLOQUEOS', 1, '{}'),
    (p_tenant, 'REENVIAR',      'INTEGRIDAD_MERCADO',     2, '{}');
  insert into clm.normative_rules (tenant_id, artifact_kind, code, kind, pattern, message, severity) values
    (p_tenant, 'ESTUDIO_PREVIO', 'EP_NECESIDAD',  'SECCION_REQUERIDA', 'necesidad',     'Falta la descripción de la necesidad', 'BLOQUEANTE'),
    (p_tenant, 'ESTUDIO_PREVIO', 'EP_OBJETO',     'SECCION_REQUERIDA', 'objeto',        'Falta el objeto a contratar', 'BLOQUEANTE'),
    (p_tenant, 'ESTUDIO_PREVIO', 'EP_VALOR',      'SECCION_REQUERIDA', 'valor_estimado','Falta el valor estimado y su justificación', 'BLOQUEANTE'),
    (p_tenant, 'ESTUDIO_PREVIO', 'EP_RIESGOS',    'SECCION_REQUERIDA', 'riesgos',       'Falta el análisis de riesgos', 'SUSTANCIAL'),
    (p_tenant, 'ESTUDIO_PREVIO', 'EP_MARCA',      'PATRON_PROHIBIDO',  '\m(marca|referencia exclusiva)\M', 'Posible exigencia de marca: restringe la competencia', 'SUSTANCIAL');
  insert into clm.approval_rules (tenant_id, min_amount, min_rigor, steps) values
    (p_tenant, 0, 1, '{JEFE_JURIDICA}'),
    (p_tenant, 0, 3, '{JEFE_AREA,JEFE_JURIDICA}');
$$;
revoke execute on function app.bootstrap_tenant(text) from public;
