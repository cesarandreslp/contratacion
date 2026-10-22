"use client";

import { useActionState } from "react";
import { crearExpediente } from "@/modules/clm/actions";

interface Opcion {
  id: string;
}
interface Props {
  unidades: (Opcion & { name: string })[];
  tipologias: (Opcion & { name: string })[];
  items: (Opcion & { label: string })[];
}

export default function NuevoExpedienteForm({ unidades, tipologias, items }: Props) {
  const [state, action, pending] = useActionState(crearExpediente, null);

  return (
    <form action={action} style={{ display: "grid", gap: "0.75rem", maxWidth: 640 }}>
      <label>
        Unidad que elabora
        <select name="originUnitId" required>
          {unidades.map((u) => <option key={u.id} value={u.id}>{u.name}</option>)}
        </select>
      </label>
      <label>
        Tipología
        <select name="contractTypeId" required>
          {tipologias.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
        </select>
      </label>
      <label>
        Ítem del Plan Anual de Adquisiciones
        <select name="planItemId" required>
          {items.map((i) => <option key={i.id} value={i.id}>{i.label}</option>)}
        </select>
      </label>
      <label>
        Objeto
        <textarea name="object" rows={3} required minLength={20} style={{ width: "100%" }} />
      </label>
      <label>
        Valor estimado (COP)
        <input name="estimatedValue" type="number" min="1" required />
      </label>
      <label>
        Plazo (días)
        <input name="estimatedDurationDays" type="number" min="1" required />
      </label>
      <label>
        Códigos UNSPSC (separados por coma)
        <input name="unspscCodes" placeholder="80111601" required />
      </label>
      <button disabled={pending}>{pending ? "Creando…" : "Crear expediente"}</button>
      {state?.error && <p style={{ color: "#f87171" }}>{state.error}</p>}
    </form>
  );
}
