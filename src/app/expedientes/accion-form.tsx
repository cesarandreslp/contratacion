"use client";

import { useActionState, useRef } from "react";
import type { ResultadoForm } from "@/modules/clm/configuracion";

// Formulario genérico para las Server Actions de configuración: muestra el error
// o el "Guardado" que devuelve la action y limpia los campos al guardar.

interface Props {
  action: (fd: FormData) => Promise<ResultadoForm>;
  label: string;
  children: React.ReactNode;
}

export default function AccionForm({ action, label, children }: Props) {
  const ref = useRef<HTMLFormElement>(null);
  const [state, formAction, pending] = useActionState(async (_: ResultadoForm | null, fd: FormData) => {
    const res = await action(fd);
    if (res.ok) ref.current?.reset();
    return res;
  }, null);

  return (
    <form ref={ref} action={formAction} style={{ display: "flex", flexWrap: "wrap", gap: "0.5rem", alignItems: "center", margin: "0.5rem 0" }}>
      {children}
      <button disabled={pending}>{pending ? "Guardando…" : label}</button>
      {state && !state.ok && <span style={{ color: "#f87171" }}>{state.error}</span>}
      {state?.ok && <span style={{ color: "#4ade80" }}>Guardado</span>}
    </form>
  );
}
