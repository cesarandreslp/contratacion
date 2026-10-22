import Link from "next/link";
import { redirect } from "next/navigation";
import { opcionesNuevoExpediente } from "@/modules/clm/actions";
import NuevoExpedienteForm from "./nuevo-form";

export default async function NuevoExpedientePage() {
  let opciones;
  try {
    opciones = await opcionesNuevoExpediente();
  } catch {
    redirect("/login");
  }
  const { unidades, tipologias, items } = opciones;
  const falta =
    unidades.length === 0
      ? "No tiene rol de elaborador o jefe de área en ninguna unidad del CLM."
      : tipologias.length === 0
        ? "La entidad no tiene tipologías contractuales configuradas."
        : items.length === 0
          ? "No hay un Plan Anual de Adquisiciones aprobado."
          : null;

  return (
    <main>
      <p style={{ margin: 0 }}><Link href="/expedientes">← Expedientes</Link></p>
      <h1>Nuevo expediente</h1>
      {falta ? (
        <p style={{ color: "var(--muted)" }}>
          {falta} Revise la <Link href="/expedientes/configuracion">configuración del CLM</Link>.
        </p>
      ) : (
        <NuevoExpedienteForm unidades={unidades} tipologias={tipologias} items={items} />
      )}
    </main>
  );
}
