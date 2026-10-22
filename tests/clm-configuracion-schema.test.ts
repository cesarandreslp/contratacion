import { describe, it, expect } from "vitest";
import {
  crearExpedienteForm,
  crearTipologiaInput,
  crearUnidadInput,
} from "@/modules/clm/configuracion-schema";

// Los formularios llegan como FormData → Object.fromEntries: todo es string.

describe("crearUnidadInput", () => {
  it("unidad raíz: parentId vacío se vuelve undefined", () => {
    const r = crearUnidadInput.parse({ parentId: "", kind: "DEPENDENCIA", code: "SEC_SALUD", name: "Secretaría de Salud" });
    expect(r.parentId).toBeUndefined();
  });

  it("rechaza códigos con espacios o minúsculas", () => {
    expect(crearUnidadInput.safeParse({ kind: "AREA", code: "salud publica", name: "Salud Pública" }).success).toBe(false);
  });
});

describe("crearTipologiaInput", () => {
  it("casillas y lista separada por comas", () => {
    const r = crearTipologiaInput.parse({
      code: "PRESTACION_SERVICIOS",
      name: "Prestación de servicios",
      requiresGuarantees: "on",
      requiredArtifacts: "ESTUDIO_PREVIO, ESTUDIO_MERCADO,",
    });
    expect(r.requiresSelection).toBe(false);
    expect(r.requiresGuarantees).toBe(true);
    expect(r.requiredArtifacts).toEqual(["ESTUDIO_PREVIO", "ESTUDIO_MERCADO"]);
  });
});

describe("crearExpedienteForm", () => {
  const base = {
    originUnitId: "3b941da1-940b-43c2-befd-969ed30d80fc",
    contractTypeId: "3b941da1-940b-43c2-befd-969ed30d80fd",
    planItemId: "3b941da1-940b-43c2-befd-969ed30d80fe",
    object: "Prestación de servicios profesionales para vigilancia epidemiológica",
    estimatedValue: "40000000",
    estimatedDurationDays: "180",
  };

  it("UNSPSC de 8 dígitos separados por coma", () => {
    expect(crearExpedienteForm.parse({ ...base, unspscCodes: "80111601,80111602" }).unspscCodes).toEqual(["80111601", "80111602"]);
  });

  it("rechaza UNSPSC mal formado", () => {
    expect(crearExpedienteForm.safeParse({ ...base, unspscCodes: "801116" }).success).toBe(false);
  });
});
