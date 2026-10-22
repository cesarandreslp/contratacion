"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { dispararTransicion } from "@/modules/clm/actions";
import type { GateFailure, TransitionCommand } from "@/modules/clm/schema";

// Datos que pide cada evento (el resto no lleva payload). Se validan con Zod en la action.
const PAYLOAD_EJEMPLO: Record<string, object> = {
  EXPEDIR_CDP: { number: "", budget_line: "", amount: 0 },
  RECHAZAR_CDP: { reason: "" },
  ASIGNAR_REVISOR: {},
  REASIGNAR_REVISOR: {},
  RECHAZAR_VOBO: { comment: "" },
  ADJUDICAR: { contract_number: "", contractor_nit: "", contractor_name: "", value: 0 },
  EXPEDIR_RP: { number: "", budget_line: "", amount: 0 },
  REGISTRAR_GARANTIA: { coverage: "CUMPLIMIENTO", insurer: "", policy_number: "", insured_amount: 0, valid_from: "", valid_to: "" },
  APROBAR_GARANTIA: { guarantee_id: "" },
  RECHAZAR_GARANTIA: { guarantee_id: "" },
  DESIGNAR_SUPERVISION: { kind: "SUPERVISION", supervisor_user_id: "" },
  DESISTIR: { reason: "" },
};

interface Props {
  dossierId: string;
  expectedVersion: number;
  event: string;
  failures: GateFailure[];
}

export default function TransicionForm({ dossierId, expectedVersion, event, failures: iniciales }: Props) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [failures, setFailures] = useState(iniciales);
  const [error, setError] = useState<string | null>(null);
  const ejemplo = PAYLOAD_EJEMPLO[event];
  const [payload, setPayload] = useState(ejemplo ? JSON.stringify(ejemplo, null, 2) : "{}");

  function ejecutar() {
    setError(null);
    startTransition(async () => {
      try {
        const res = await dispararTransicion({
          dossierId,
          expectedVersion,
          event,
          payload: JSON.parse(payload),
        } as TransitionCommand);
        if (res.ok) return router.refresh();
        if (res.error.kind === "COMPUERTA_BLOQUEADA") setFailures(res.error.failures);
        else if (res.error.kind === "CONFLICTO_DE_VERSION") {
          setError("Otra persona movió el expediente. Se recargó el estado.");
          router.refresh();
        } else setError(res.error.code.replaceAll("_", " "));
      } catch (err) {
        setError(err instanceof Error ? err.message : "Error");
      }
    });
  }

  return (
    <div style={{ borderTop: "1px solid #334155", padding: "0.75rem 0" }}>
      <strong>{event.replaceAll("_", " ")}</strong>
      {failures.length === 0 ? (
        <p style={{ color: "#4ade80", margin: "0.25rem 0" }}>✓ Compuertas cumplidas</p>
      ) : (
        <ul style={{ margin: "0.25rem 0", color: "#fbbf24" }}>
          {failures.map((f) => (
            <li key={f.check + f.message}>
              {f.hard ? "Requisito legal" : "Regla de la entidad"} · {f.message}
            </li>
          ))}
        </ul>
      )}
      {ejemplo && Object.keys(ejemplo).length > 0 && (
        <textarea
          value={payload}
          onChange={(e) => setPayload(e.target.value)}
          rows={Object.keys(ejemplo).length + 2}
          style={{ width: "100%", fontFamily: "monospace" }}
        />
      )}
      <button onClick={ejecutar} disabled={pending || failures.length > 0}>
        {pending ? "Procesando…" : "Ejecutar"}
      </button>
      {error && <p style={{ color: "#f87171" }}>{error}</p>}
    </div>
  );
}
