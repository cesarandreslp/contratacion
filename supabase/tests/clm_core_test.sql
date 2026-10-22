-- Prueba end-to-end del Core Engine: aislamiento, RLS jerárquica, compuertas,
-- bucle de revisión, cadena de VoBo, sello, firma, habilitación y auditoría.
-- Ejecutar con: supabase/tests/run.sh
\set ON_ERROR_STOP on
\set QUIET on

\set A     '10000000-0000-0000-0000-00000000000a'
\set B     '10000000-0000-0000-0000-00000000000b'
\set SEC   '20000000-0000-0000-0000-000000000001'
\set AREA  '20000000-0000-0000-0000-000000000002'
\set OAJ   '20000000-0000-0000-0000-000000000003'
\set BU    '20000000-0000-0000-0000-000000000004'
\set elab  '30000000-0000-0000-0000-000000000001'
\set presu '30000000-0000-0000-0000-000000000002'
\set coord '30000000-0000-0000-0000-000000000003'
\set rev   '30000000-0000-0000-0000-000000000004'
\set jj    '30000000-0000-0000-0000-000000000005'
\set orden '30000000-0000-0000-0000-000000000006'
\set elabB '30000000-0000-0000-0000-000000000007'
\set CT    '40000000-0000-0000-0000-000000000001'
\set PLAN  '50000000-0000-0000-0000-000000000001'
\set ITEM  '60000000-0000-0000-0000-000000000001'

-- ---------------------------------------------------------------- utilidades
create schema t;
grant usage on schema t to authenticated, service_role;

create function t.login(p_user uuid) returns void language plpgsql security definer as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_user, 'role', 'authenticated',
    'app_metadata', json_build_object('tenant_id', (select tenant_id from public.users where id = p_user)))::text, false);
end $$;
create function t.login_service() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role":"service_role"}', false)
$$;
create function t.fire(p_dossier uuid, p_event text, p_payload jsonb default '{}') returns text language plpgsql as $$
declare v int;
begin
  select state_version into v from public.dossiers where id = p_dossier;
  return (public.transition(p_dossier, p_event, v, p_payload)).state::text;
end $$;
create function t.expect_error(p_sql text, p_pattern text) returns void language plpgsql as $$
declare v_detail text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
    if (sqlerrm || ' ' || coalesce(v_detail, '')) ~* p_pattern then
      raise notice 'ok  bloqueado: % → %', left(p_sql, 60), sqlerrm;
      return;
    end if;
    raise exception 'error inesperado en [%]: % %', p_sql, sqlerrm, v_detail;
  end;
  raise exception 'esperaba error /%/ y no hubo: %', p_pattern, p_sql;
end $$;
create function t.ok(p boolean, p_msg text) returns void language plpgsql as $$
begin
  if p is not true then raise exception 'FALLA: %', p_msg; end if;
  raise notice 'ok  %', p_msg;
end $$;
grant execute on all functions in schema t to authenticated, service_role;

-- ---------------------------------------------------------------- datos base (superusuario)
insert into public.tenants (id, slug, name, nit, territorial_order) values
  (:'A', 'gob-demo',   'Gobernación Demo', '890000001', 'DEPARTAMENTAL'),
  (:'B', 'alcaldia-x', 'Alcaldía X',       '890000002', 'MUNICIPAL');
insert into public.organizational_units (id, tenant_id, parent_id, kind, code, name) values
  (:'SEC',  :'A', null,   'DEPENDENCIA',      'SEC_SALUD',     'Secretaría de Salud'),
  (:'AREA', :'A', :'SEC', 'AREA',             'SALUD_PUBLICA', 'Salud Pública'),
  (:'OAJ',  :'A', null,   'JURIDICA_CENTRAL', 'OAJ',           'Oficina Asesora Jurídica'),
  (:'BU',   :'B', null,   'DEPENDENCIA',      'SEC_GOB',       'Secretaría de Gobierno');
insert into auth.users (id) select unnest(array[:'elab', :'presu', :'coord', :'rev', :'jj', :'orden', :'elabB']::uuid[]);
insert into public.users (id, tenant_id, full_name, email) values
  (:'elab',  :'A', 'Elaboradora',      'e@a.gov.co'),
  (:'presu', :'A', 'Presupuesto',      'p@a.gov.co'),
  (:'coord', :'A', 'Coordinador OAJ',  'c@a.gov.co'),
  (:'rev',   :'A', 'Abogada revisora', 'r@a.gov.co'),
  (:'jj',    :'A', 'Jefe jurídica',    'j@a.gov.co'),
  (:'orden', :'A', 'Secretario',       'o@a.gov.co'),
  (:'elabB', :'B', 'Elaborador B',     'e@b.gov.co');
insert into public.user_memberships (tenant_id, user_id, unit_id, role, scope) values
  (:'A', :'elab',  :'AREA', 'ELABORADOR',               'UNIT'),
  (:'A', :'presu', :'SEC',  'PRESUPUESTO',              'TENANT'),
  (:'A', :'coord', :'OAJ',  'COORDINADOR_CONTRATACION', 'UNIT'),
  (:'A', :'rev',   :'OAJ',  'REVISOR_JURIDICO',         'UNIT'),
  (:'A', :'jj',    :'OAJ',  'JEFE_JURIDICA',            'UNIT'),
  (:'A', :'orden', :'SEC',  'ORDENADOR_GASTO',          'SUBTREE'),
  (:'B', :'elabB', :'BU',   'ELABORADOR',               'UNIT');
insert into public.contract_types (id, tenant_id, code, name, required_artifacts)
values (:'CT', :'A', 'PRESTACION_SERVICIOS', 'Prestación de servicios', '{ESTUDIO_PREVIO}');
insert into public.procurement_plans (id, tenant_id, fiscal_year, status, approved_at)
values (:'PLAN', :'A', extract(year from now()), 'APROBADO', now());
insert into public.procurement_plan_items (id, tenant_id, plan_id, unit_id, code, description, unspsc_codes,
                                           estimated_value, modality, expected_start, duration_days)
values (:'ITEM', :'A', :'PLAN', :'SEC', 'PAA-001', 'Apoyo vigilancia epidemiológica', '{80111600}',
        100000000, 'DIRECTA', current_date, 180);
insert into public.document_templates (tenant_id, contract_type_id, version, body) values (:'A', :'CT', 1,
E'CONTRATO No. {{contrato.numero}}\n\nEntre {{entidad.nombre}} (NIT {{entidad.nit}}) y {{contrato.contratista}} (NIT {{contrato.nit_contratista}}).\n\nObjeto: {{expediente.objeto}}. Valor: {{contrato.valor}}. CDP {{cdp.numero}}.\n\nSello precontractual: {{sello}}');
select app.bootstrap_tenant(:'A');
insert into public.approval_rules (tenant_id, contract_type_id, min_amount, steps)
values (:'A', :'CT', 30000000, '{JEFE_JURIDICA,ORDENADOR_GASTO}');
insert into ref.company_registry (nit, name, legal_rep_hashes, status, source) values
  ('900111', 'Consultores A', '{h-rep-1}', 'ACTIVA', 'RUES'),
  ('900222', 'Consultores B', '{h-rep-1}', 'ACTIVA', 'RUES'),     -- mismo representante que A
  ('900333', 'Consultores C', '{h-rep-3}', 'ACTIVA', 'RUES');

-- ---------------------------------------------------------------- 1. creación y aislamiento
set role authenticated;
select t.login(:'elab');
insert into public.dossiers (tenant_id, origin_unit_id, contract_type_id, plan_item_id, object,
                             estimated_value, estimated_duration_days, unspsc_codes)
values (:'A', :'AREA', :'CT', :'ITEM', 'Prestación de servicios profesionales para vigilancia epidemiológica',
        50000000, 180, '{80111601}')
returning id as dos \gset
select t.ok((select rigor_level from public.dossiers where id = :'dos') = 2, 'rigor por defecto sin historial = 2');

select t.login(:'elabB');
select t.ok((select count(*) from public.dossiers) = 0, 'otro tenant no ve el expediente');
select t.ok((select count(*) from public.audit_events) = 0, 'otro tenant no ve la bitácora');
select t.expect_error(format($$insert into public.dossiers (tenant_id, origin_unit_id, contract_type_id, object, estimated_value, estimated_duration_days)
  values (%L, %L, %L, 'Intento de crear en tenant ajeno, debe fallar', 1, 1)$$, :'A', :'AREA', :'CT'), 'row-level security');

select t.login(:'coord');
select t.ok((select count(*) from public.dossiers) = 0, 'jurídica no ve el borrador antes de radicar');

-- ---------------------------------------------------------------- 2. elaboración con IA trazable
select t.login(:'elab');
insert into public.artifacts (tenant_id, dossier_id, kind, title) values (:'A', :'dos', 'ESTUDIO_PREVIO', 'Estudio previo')
returning id as ep \gset
select t.expect_error(format($$insert into public.ai_generations (tenant_id, dossier_id, artifact_id, block_id, task, model, prompt_version, prompt_hash, output)
  values (%L, %L, %L, 'b4', 'VALOR_ESTIMADO', 'm', 'v1', 'h', '{"valor": 1}')$$, :'A', :'dos', :'ep'), 'check constraint');
insert into public.ai_generations (tenant_id, dossier_id, artifact_id, block_id, task, model, prompt_version, prompt_hash, citations, output)
values (:'A', :'dos', :'ep', 'b4', 'VALOR_ESTIMADO', 'glm-4-flash', 'v1', 'h',
        '[{"kind":"price_benchmark","id":"80111601|MES|2026-06-30"}]', '{"valor": 50000000}')
returning id as gen \gset
update public.artifacts set draft = jsonb_build_object('blocks', jsonb_build_array(
  jsonb_build_object('id','b1','type','paragraph','section','necesidad','text','La Secretaría requiere apoyo...','provenance',jsonb_build_object('origin','HUMAN')),
  jsonb_build_object('id','b2','type','paragraph','section','objeto','text','Prestar servicios profesionales...','provenance',jsonb_build_object('origin','AI_EDITED','generation_id',null)),
  jsonb_build_object('id','b3','type','paragraph','section','riesgos','text','Riesgo de mora...','provenance',jsonb_build_object('origin','HUMAN')),
  jsonb_build_object('id','b4','type','value','section','valor_estimado','text','$50.000.000','value',50000000,
                     'provenance',jsonb_build_object('origin','AI','generation_id', :'gen'))))
 where id = :'ep';
insert into public.artifact_versions (artifact_id) values (:'ep') returning id as v10, label as lbl \gset
select t.ok(:'lbl' = 'v1.0', 'primera versión = v1.0');

select t.expect_error(format('select t.fire(%L, %L)', :'dos', 'SOLICITAR_CDP'), 'AUTORIA_RATIFICADA');
insert into public.authorship_attestations (version_id) values (:'v10');
select t.expect_error(format('select t.fire(%L, %L)', :'dos', 'SOLICITAR_CDP'), 'VALORES_IA_SOPORTADOS');
update public.ai_generations set decision = 'ACEPTADA' where id = :'gen';
select t.expect_error(format('select t.fire(%L, %L)', :'dos', 'SOLICITAR_CDP'), 'COTIZACIONES_MINIMAS');

-- ---------------------------------------------------------------- 3. integridad de mercado
insert into public.market_quotes (tenant_id, dossier_id, supplier_nit, supplier_name, amount, quote_date) values
  (:'A', :'dos', '900111', 'Consultores A', 50000000, current_date),
  (:'A', :'dos', '900222', 'Consultores B', 52000000, current_date);
select t.ok((select count(*) from public.scan_market_integrity(:'dos') f where f.kind = 'VINCULO_CRUZADO') = 1,
            'detecta representante legal común entre cotizantes');
select t.expect_error(format('select t.fire(%L, %L)', :'dos', 'SOLICITAR_CDP'), 'INTEGRIDAD_MERCADO');
delete from public.market_quotes where dossier_id = :'dos' and supplier_nit = '900222';
insert into public.market_quotes (tenant_id, dossier_id, supplier_nit, supplier_name, amount, quote_date)
values (:'A', :'dos', '900333', 'Consultores C', 48000000, current_date);
select t.ok((select count(*) from public.scan_market_integrity(:'dos')) = 0, 'cotizantes independientes: sin hallazgos');

select t.expect_error(format($$update public.dossiers set state = 'APROBADO' where id = %L$$, :'dos'), 'permission denied');
select t.ok(t.fire(:'dos', 'SOLICITAR_CDP') = 'PENDIENTE_CDP', 'SOLICITAR_CDP → PENDIENTE_CDP');

-- ---------------------------------------------------------------- 4. presupuesto y enrutamiento
select t.expect_error(format('select t.fire(%L, %L, %L)', :'dos', 'EXPEDIR_CDP', '{}'), 'ROL_NO_AUTORIZADO');
select t.login(:'presu');
select t.expect_error(format('select t.fire(%L, %L, %L)', :'dos', 'EXPEDIR_CDP',
  '{"number":"CDP-1","budget_line":"2.1.2","amount":1000}'), 'CDP_INSUFICIENTE');
select t.ok(t.fire(:'dos', 'EXPEDIR_CDP', '{"number":"CDP-001","budget_line":"2.1.2.02","amount":50000000}') = 'EN_COLA_JURIDICA',
            'EXPEDIR_CDP → EN_COLA_JURIDICA');
select t.ok((select review_unit_id from public.dossiers where id = :'dos') = :'OAJ', 'sin delegación: enruta a la jurídica central');

select t.login(:'coord');
select t.ok(t.fire(:'dos', 'ASIGNAR_REVISOR') = 'EN_REVISION_JURIDICA', 'asignación por balanceo de carga');
select t.ok((select assigned_reviewer_id from public.dossiers where id = :'dos') = :'rev', 'quedó asignada la revisora competente');

-- ---------------------------------------------------------------- 5. bucle de revisión
select t.login(:'elab');
update public.artifacts set title = 'cambio furtivo' where id = :'ep';
select t.ok((select title from public.artifacts where id = :'ep') = 'Estudio previo', 'elaborador congelado durante la revisión');
select t.expect_error(format('insert into public.artifact_versions (artifact_id) values (%L)', :'ep'), 'EXPEDIENTE_NO_EDITABLE');
select t.expect_error(format($$insert into public.observations (dossier_id, artifact_id, severity, category, body)
  values (%L, %L, 'FORMA', 'X', 'el elaborador no observa')$$, :'dos', :'ep'), 'row-level security');

select t.login(:'rev');
select t.expect_error(format('select t.fire(%L, %L)', :'dos', 'DEVOLVER'), 'HAY_OBSERVACIONES_ABIERTAS');
insert into public.observations (dossier_id, artifact_id, block_id, severity, category, body)
values (:'dos', :'ep', 'b3', 'BLOQUEANTE', 'JURIDICA', 'La matriz de riesgos no asigna responsables ni mitigaciones.')
returning id as obs \gset
select t.ok(t.fire(:'dos', 'DEVOLVER') = 'EN_SUBSANACION', 'DEVOLVER → EN_SUBSANACION');
select t.expect_error(format($$insert into public.observations (dossier_id, artifact_id, severity, category, body)
  values (%L, %L, 'FORMA', 'X', 'revisor congelado en subsanación')$$, :'dos', :'ep'), 'row-level security');

select t.login(:'elab');
select t.expect_error(format('select t.fire(%L, %L)', :'dos', 'REENVIAR'), 'OBSERVACIONES_RESPONDIDAS');
update public.artifacts set draft = jsonb_set(draft, '{blocks,2,text}', '"Riesgo de mora: lo asume el contratista; mitigación: garantía de cumplimiento."')
 where id = :'ep';
insert into public.artifact_versions (artifact_id) values (:'ep') returning id as v20, label as lbl \gset
select t.ok(:'lbl' = 'v2.0', 'versión tras devolución = v2.0');
insert into public.authorship_attestations (version_id) values (:'v20');
select t.expect_error(format($$insert into public.observation_responses (observation_id, resolution, justification, corrected_version_id)
  values (%L, 'CORREGIDA', 'Se asignaron responsables y mitigaciones.', %L)$$, :'obs', :'v10'), 'VERSION_CORRECTIVA_INVALIDA');
insert into public.observation_responses (observation_id, resolution, justification, corrected_version_id)
values (:'obs', 'CORREGIDA', 'Se asignaron responsables y mitigaciones.', :'v20');
select t.ok(t.fire(:'dos', 'REENVIAR') = 'EN_REVISION_JURIDICA', 'REENVIAR → EN_REVISION_JURIDICA');
select t.ok((select count(*) from public.diff_versions(:'v10', :'v20') where change = 'MODIFIED') = 1, 'diff: un bloque modificado');

select t.login(:'rev');
select t.expect_error(format('select t.fire(%L, %L)', :'dos', 'APROBAR_REVISION'), 'SIN_OBSERVACIONES_BLOQUEANTES');
select t.expect_error(format($$update public.observations set status = 'RESPONDIDA' where id = %L$$, :'obs'), 'row-level security|TRANSICION_DE_OBSERVACION');
update public.observations set status = 'ACEPTADA' where id = :'obs';
select t.ok(t.fire(:'dos', 'APROBAR_REVISION') = 'EN_CADENA_VOBO', 'APROBAR_REVISION → EN_CADENA_VOBO');

-- ---------------------------------------------------------------- 6. cadena de VoBo y sello
select t.login(:'orden');
select t.expect_error(format('select t.fire(%L, %L)', :'dos', 'VOBO'), 'NO_LE_CORRESPONDE_ESTE_VOBO');
select t.login(:'jj');
select t.ok(t.fire(:'dos', 'VOBO', '{"comment":"Conforme"}') = 'EN_CADENA_VOBO', 'VoBo jefe jurídica (sigue la cadena)');
select t.login(:'orden');
select t.ok(t.fire(:'dos', 'VOBO') = 'APROBADO', 'VoBo ordenador del gasto → APROBADO');
select t.ok((select seal_hash is not null from public.dossiers where id = :'dos'), 'expediente sellado');
select t.ok((select bool_and(a.sealed_at is not null) from public.artifacts a where a.dossier_id = :'dos'), 'artefactos sellados');
select t.ok((select s3.prev_hash = s2.step_hash and s2.prev_hash = s1.step_hash
               from public.approval_steps s1, public.approval_steps s2, public.approval_steps s3
              where s1.dossier_id = :'dos' and s1.seq = 1 and s2.dossier_id = :'dos' and s2.seq = 2
                and s3.dossier_id = :'dos' and s3.seq = 3), 'VoBo encadenados por hash');

-- ---------------------------------------------------------------- 7. adjudicación, ensamblado y perfeccionamiento
select t.ok(t.fire(:'dos', 'ADJUDICAR', '{"contract_number":"CT-2026-001","contractor_nit":"900333","contractor_name":"Consultores C","value":48000000}') = 'ADJUDICADO',
            'ADJUDICAR → ADJUDICADO');
select t.login(:'coord');
select t.ok(t.fire(:'dos', 'ENSAMBLAR_CONTRATO') = 'ADJUDICADO', 'contrato ensamblado desde plantilla');
select a.current_version_id as cv, (v.content -> 'blocks' -> 0 ->> 'text') as txt
  from public.artifacts a join public.artifact_versions v on v.id = a.current_version_id
 where a.dossier_id = :'dos' and a.kind = 'CONTRATO' \gset
select t.ok(:'txt' = 'CONTRATO No. CT-2026-001', 'la minuta lleva los datos validados');
insert into public.signature_requests (tenant_id, dossier_id, artifact_version_id, provider, pdf_sha256, signers)
values (:'A', :'dos', :'cv', 'mock', 'abc', '[]') returning id as sig \gset
select t.expect_error(format('select t.fire(%L, %L, %L)', :'dos', 'PERFECCIONAR', json_build_object('signature_request_id', :'sig')), 'SOLO_SISTEMA');

reset role;
update public.signature_requests set status = 'FIRMADA', completed_at = now() where id = :'sig';  -- webhook del proveedor
set role service_role;
select t.login_service();
select t.ok(t.fire(:'dos', 'PERFECCIONAR', json_build_object('signature_request_id', :'sig')::jsonb) = 'PERFECCIONADO',
            'PERFECCIONAR (webhook de firma) → PERFECCIONADO');

-- ---------------------------------------------------------------- 8. habilitación de ejecución
set role authenticated;
select t.login(:'orden');
select t.expect_error(format('select t.fire(%L, %L)', :'dos', 'HABILITAR_EJECUCION'), 'RP_EXPEDIDO.*GARANTIAS_APROBADAS.*SUPERVISION_DESIGNADA');
select t.login(:'presu');
select t.fire(:'dos', 'EXPEDIR_RP', '{"number":"RP-001","budget_line":"2.1.2.02","amount":48000000}');
select t.login(:'coord');
select t.fire(:'dos', 'REGISTRAR_GARANTIA', '{"coverage":"CUMPLIMIENTO","insurer":"Aseguradora X","policy_number":"P-1","insured_amount":4800000,"valid_from":"2026-11-01","valid_to":"2027-07-01"}');
select id as gar from public.guarantees where dossier_id = :'dos' \gset
select t.login(:'jj');
select t.fire(:'dos', 'APROBAR_GARANTIA', json_build_object('guarantee_id', :'gar')::jsonb);
select t.login(:'orden');
select t.fire(:'dos', 'DESIGNAR_SUPERVISION', json_build_object('kind', 'SUPERVISION', 'supervisor_user_id', :'elab')::jsonb);
select t.ok(t.fire(:'dos', 'HABILITAR_EJECUCION') = 'EJECUCION_HABILITADA', 'HABILITAR_EJECUCION → EJECUCION_HABILITADA');

-- ---------------------------------------------------------------- 9. inmutabilidad y auditoría
reset role;
select t.expect_error(format($$update public.artifact_versions set content = '{}' where id = %L$$, :'v10'), 'REGISTRO_INMUTABLE');
select t.expect_error('delete from public.audit_events', 'REGISTRO_INMUTABLE');
select t.expect_error(format($$update public.organizational_units set parent_id = %L where id = %L$$, :'AREA', :'SEC'), 'ORGANIGRAMA_CICLICO');
select t.ok(app.verify_audit_chain(:'A') is null, format('cadena de auditoría íntegra (%s eventos)', (select count(*) from public.audit_events where tenant_id = :'A')));
select id as victima from public.audit_events where tenant_id = :'A' order by id offset 3 limit 1 \gset
begin;
alter table public.audit_events disable trigger audit_events_append_only;
update public.audit_events set payload = '{"alterado":true}' where id = :'victima';
select t.ok(app.verify_audit_chain(:'A') = :'victima', 'manipulación de la bitácora detectada');
rollback;

-- ---------------------------------------------------------------- 10. gemelo de datos → rigor
insert into public.contract_modifications (tenant_id, dossier_id, contract_id, kind, value_delta, signed_at, created_by)
select :'A', :'dos', id, 'ADICION', 20000000, current_date, :'jj' from public.contracts where dossier_id = :'dos';
update public.tenants set settings = jsonb_set(settings, '{rigor,min_sample}', '1') where id = :'A';
refresh materialized view app.unit_planning_scores;
select t.ok(app.compute_rigor(:'A', :'AREA', :'CT') = 3, 'desviación de 36% en el valor ⇒ el área pasa a rigor 3');

\echo 'TODAS LAS PRUEBAS PASARON'
