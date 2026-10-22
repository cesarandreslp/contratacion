import Link from "next/link";
import { redirect } from "next/navigation";
import { listarExpedientes } from "@/modules/clm/actions";
import { pesos } from "./formato";

export default async function ExpedientesPage() {
  let expedientes;
  try {
    expedientes = await listarExpedientes();
  } catch {
    redirect("/login");
  }

  return (
    <main>
      <h1>Expedientes precontractuales</h1>
      <p style={{ display: "flex", gap: "1rem" }}>
        <Link href="/expedientes/nuevo">+ Nuevo expediente</Link>
        <Link href="/expedientes/configuracion">Configuración del CLM</Link>
      </p>
      {expedientes.length === 0 ? (
        <p style={{ color: "var(--muted)" }}>No tiene expedientes visibles en sus dependencias.</p>
      ) : (
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr style={{ textAlign: "left", color: "var(--muted)" }}>
              <th>No.</th>
              <th>Objeto</th>
              <th>Dependencia</th>
              <th>Valor</th>
              <th>Estado</th>
            </tr>
          </thead>
          <tbody>
            {expedientes.map((e) => (
              <tr key={e.id} style={{ borderTop: "1px solid #334155" }}>
                <td>
                  <Link href={`/expedientes/${e.id}`}>{e.number}</Link>
                </td>
                <td>{e.object.slice(0, 90)}</td>
                <td>{e.origin_unit}</td>
                <td>{pesos(e.estimated_value)}</td>
                <td>{e.state.replaceAll("_", " ")}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </main>
  );
}
