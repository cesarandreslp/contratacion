import { notFound, redirect } from "next/navigation";
import { obtenerExpediente } from "@/modules/clm/actions";
import { pesos } from "../formato";
import TransicionForm from "./transicion-form";

const panel = { background: "var(--panel)", borderRadius: 8, padding: "1rem", marginBottom: "1rem" };

export default async function ExpedientePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  let data;
  try {
    data = await obtenerExpediente(id);
  } catch {
    redirect("/login");
  }
  if (!data) notFound();
  const { dossier: d, artifacts, observations, steps, eventos } = data;

  return (
    <main>
      <p style={{ color: "var(--muted)", margin: 0 }}>Expediente {d.number}</p>
      <h1 style={{ marginTop: "0.25rem" }}>{d.object}</h1>
      <p>
        <strong>{d.state.replaceAll("_", " ")}</strong> · {pesos(d.estimated_value)} · rigor {d.rigor_level} ·{" "}
        {d.origin_unit}
        {d.review_unit && <> → revisa {d.review_unit}</>}
      </p>
      {d.seal_hash && (
        <p style={{ color: "var(--muted)", fontFamily: "monospace", fontSize: "0.8rem" }}>
          Sello {d.seal_hash.slice(0, 16)}…
        </p>
      )}

      <section style={panel}>
        <h2>Siguiente paso</h2>
        {eventos.length === 0 ? (
          <p style={{ color: "var(--muted)" }}>No hay eventos disponibles en este estado.</p>
        ) : (
          eventos.map((ev) => (
            <TransicionForm
              key={ev.event}
              dossierId={d.id}
              expectedVersion={d.state_version}
              event={ev.event}
              failures={ev.failures}
            />
          ))
        )}
      </section>

      <section style={panel}>
        <h2>Artefactos</h2>
        <ul>
          {artifacts.map((a) => (
            <li key={a.kind}>
              {a.title} — {a.label ?? "sin versión"} {a.sealed && "· sellado"}
            </li>
          ))}
        </ul>
      </section>

      {observations.length > 0 && (
        <section style={panel}>
          <h2>Observaciones pendientes</h2>
          <ul>
            {observations.map((o) => (
              <li key={o.id}>
                <strong>{o.severity}</strong> · {o.artifact}
                {o.block_id && ` #${o.block_id}`} · {o.status} — {o.body}
              </li>
            ))}
          </ul>
        </section>
      )}

      {steps.length > 0 && (
        <section style={panel}>
          <h2>Cadena de vistos buenos</h2>
          <ol>
            {steps.map((s) => (
              <li key={s.seq}>
                {s.role.replaceAll("_", " ")} — {s.status}
                {s.decided_at && ` (${s.decided_at.toLocaleString("es-CO")})`}
              </li>
            ))}
          </ol>
        </section>
      )}
    </main>
  );
}
