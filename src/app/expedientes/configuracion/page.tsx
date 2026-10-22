import Link from "next/link";
import { redirect } from "next/navigation";
import {
  activarClm,
  agregarItemPaa,
  aprobarPlan,
  crearDelegacion,
  crearPlan,
  crearTipologia,
  crearUnidad,
  estadoClm,
  otorgarRol,
  revocarRol,
} from "@/modules/clm/configuracion";
import { appRole } from "@/modules/clm/schema";
import AccionForm from "../accion-form";
import { pesos } from "../formato";

const panel = { background: "var(--panel)", borderRadius: 8, padding: "1rem", marginBottom: "1rem" };
const muted = { color: "var(--muted)" };
const KINDS = ["DEPENDENCIA", "AREA", "UNIDAD_CONTRATACION", "JURIDICA_CENTRAL"];

export default async function ConfiguracionClmPage() {
  let e;
  try {
    e = await estadoClm();
  } catch {
    redirect("/login");
  }

  if (!e.activo) {
    return (
      <main>
        <h1>Configuración del CLM</h1>
        {e.esAdminTenant ? (
          <section style={panel}>
            <p>El módulo precontractual no está activo para esta entidad. Al activarlo se crea la oficina jurídica central y usted queda como administrador del CLM.</p>
            <AccionForm action={activarClm} label="Activar CLM">
              <select name="territorialOrder" defaultValue="MUNICIPAL">
                {["NACIONAL", "DEPARTAMENTAL", "DISTRITAL", "MUNICIPAL"].map((o) => <option key={o}>{o}</option>)}
              </select>
              <input name="juridicaNombre" placeholder="Oficina Asesora Jurídica" required />
            </AccionForm>
          </section>
        ) : (
          <p style={muted}>El módulo no está activo. Pídale al administrador de la entidad que lo active.</p>
        )}
      </main>
    );
  }

  const nombre = (id: string) => e.usuarios.find((u) => u.id === id)?.nombre ?? id;
  const selUnidad = (name: string, opcional = false) => (
    <select name={name} required={!opcional} defaultValue="">
      <option value="">{opcional ? "— sin unidad padre —" : "Unidad…"}</option>
      {e.unidades.map((u) => <option key={u.id} value={u.id}>{"· ".repeat(u.depth - 1) + u.name}</option>)}
    </select>
  );

  return (
    <main>
      <p style={{ margin: 0 }}><Link href="/expedientes">← Expedientes</Link></p>
      <h1>Configuración del CLM</h1>
      <p style={muted}>Los cambios requieren el rol ADMIN_ENTIDAD (el PAA, PLANEACION) con alcance de entidad.</p>

      <section style={panel}>
        <h2>Organigrama</h2>
        <ul style={{ listStyle: "none", paddingLeft: 0 }}>
          {e.unidades.map((u) => (
            <li key={u.id} style={{ paddingLeft: `${(u.depth - 1) * 1.25}rem` }}>
              {u.name} <span style={muted}>· {u.code} · {u.kind.replaceAll("_", " ")}</span>
            </li>
          ))}
        </ul>
        <AccionForm action={crearUnidad} label="Agregar unidad">
          {selUnidad("parentId", true)}
          <select name="kind">{KINDS.map((k) => <option key={k}>{k}</option>)}</select>
          <input name="code" placeholder="SEC_SALUD" required />
          <input name="name" placeholder="Secretaría de Salud" required />
        </AccionForm>
      </section>

      <section style={panel}>
        <h2>Roles por unidad</h2>
        <ul>
          {e.membresias.map((m) => (
            <li key={m.id}>
              <AccionForm action={revocarRol} label="Revocar">
                <span>{nombre(m.user_id)} — {m.role.replaceAll("_", " ")} en {m.unit} ({m.scope})</span>
                <input type="hidden" name="id" value={m.id} />
              </AccionForm>
            </li>
          ))}
        </ul>
        <AccionForm action={otorgarRol} label="Otorgar rol">
          <select name="userId" required defaultValue="">
            <option value="">Usuario…</option>
            {e.usuarios.map((u) => <option key={u.id} value={u.id}>{u.nombre} · {u.email}</option>)}
          </select>
          <select name="role">{appRole.options.map((r) => <option key={r}>{r}</option>)}</select>
          {selUnidad("unitId")}
          <select name="scope" defaultValue="UNIT">
            <option value="UNIT">Solo la unidad</option>
            <option value="SUBTREE">Unidad y dependientes</option>
            <option value="TENANT">Toda la entidad</option>
          </select>
        </AccionForm>
      </section>

      <section style={panel}>
        <h2>Delegación de revisión jurídica</h2>
        <p style={muted}>Sin delegación, los expedientes van a la jurídica central. Se toma la del ancestro más cercano.</p>
        <ul>
          {e.delegaciones.map((d, i) => (
            <li key={i}>{d.origen} → {d.revisa}{d.tipologia && ` · solo ${d.tipologia}`}{d.min_amount > 0 && ` · desde ${pesos(d.min_amount)}`}</li>
          ))}
        </ul>
        <AccionForm action={crearDelegacion} label="Agregar delegación">
          {selUnidad("originUnitId")}
          <span>revisa</span>
          {selUnidad("reviewUnitId")}
          <select name="contractTypeId" defaultValue="">
            <option value="">Toda tipología</option>
            {e.tipologias.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
          <input name="minAmount" type="number" min="0" placeholder="Cuantía mínima" />
        </AccionForm>
      </section>

      <section style={panel}>
        <h2>Tipologías contractuales</h2>
        <ul>
          {e.tipologias.map((t) => (
            <li key={t.id}>
              {t.name} <span style={muted}>· {t.code} · {t.requires_selection ? "con selección" : "directa"} ·{" "}
              {t.requires_guarantees ? "con garantías" : "sin garantías"} · exige {t.required_artifacts.join(", ")}</span>
            </li>
          ))}
        </ul>
        <AccionForm action={crearTipologia} label="Agregar tipología">
          <input name="code" placeholder="PRESTACION_SERVICIOS" required />
          <input name="name" placeholder="Prestación de servicios" required />
          <input name="requiredArtifacts" defaultValue="ESTUDIO_PREVIO,ESTUDIO_MERCADO,MATRIZ_RIESGOS" size={40} />
          <label><input type="checkbox" name="requiresSelection" /> Con selección</label>
          <label><input type="checkbox" name="requiresGuarantees" defaultChecked /> Con garantías</label>
        </AccionForm>
      </section>

      <section style={panel}>
        <h2>Plan Anual de Adquisiciones</h2>
        {e.planes.map((p) => (
          <div key={p.id}>
            <h3>Vigencia {p.fiscal_year} · v{p.version} · {p.status}</h3>
            <ul>
              {e.items.filter((i) => i.plan_id === p.id).map((i) => (
                <li key={i.id}>{i.code} · {i.unit} · {i.description} · {pesos(i.estimated_value)} <span style={muted}>· {i.unspsc.join(", ")}</span></li>
              ))}
            </ul>
            {p.status === "BORRADOR" && (
              <>
                <AccionForm action={agregarItemPaa} label="Agregar ítem">
                  <input type="hidden" name="planId" value={p.id} />
                  {selUnidad("unitId")}
                  <input name="code" placeholder="PAA-001" required size={8} />
                  <input name="description" placeholder="Descripción" required />
                  <input name="unspscCodes" placeholder="80111600" required size={12} />
                  <input name="estimatedValue" type="number" min="1" placeholder="Valor" required />
                  <input name="modality" placeholder="DIRECTA" required size={10} />
                  <input name="expectedStart" type="date" required />
                  <input name="durationDays" type="number" min="1" placeholder="Días" required size={5} />
                </AccionForm>
                <AccionForm action={aprobarPlan} label="Aprobar plan (lo congela)">
                  <input type="hidden" name="id" value={p.id} />
                </AccionForm>
              </>
            )}
          </div>
        ))}
        <AccionForm action={crearPlan} label="Nuevo plan">
          <input name="fiscalYear" type="number" defaultValue={new Date().getFullYear()} required />
        </AccionForm>
      </section>
    </main>
  );
}
