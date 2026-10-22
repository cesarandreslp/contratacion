import { describe, it, expect } from "vitest";
import { clmErrorCode, transitionCommand, transitionErrorFromCode } from "@/modules/clm/schema";

const base = { dossierId: "70000000-0000-0000-0000-000000000002", expectedVersion: 1 };

describe("transitionCommand", () => {
  it("EXPEDIR_CDP exige número, rubro y valor", () => {
    expect(transitionCommand.safeParse({ ...base, event: "EXPEDIR_CDP", payload: {} }).success).toBe(false);
    expect(
      transitionCommand.safeParse({
        ...base,
        event: "EXPEDIR_CDP",
        payload: { number: "CDP-1", budget_line: "2.3", amount: 30000000 },
      }).success,
    ).toBe(true);
  });

  it("eventos sin datos rechazan payload extra", () => {
    expect(transitionCommand.safeParse({ ...base, event: "DEVOLVER", payload: { x: 1 } }).success).toBe(false);
  });

  it("PERFECCIONAR no se puede disparar desde la app (solo el webhook de firma)", () => {
    expect(transitionCommand.safeParse({ ...base, event: "PERFECCIONAR", payload: {} }).success).toBe(false);
  });
});

describe("clmErrorCode", () => {
  it("extrae el código del error que Prisma envuelve", () => {
    const err = new Error("Invalid `prisma.$queryRaw()` invocation:\n\nRaw query failed. Code: `P0001`. Message: `COMPUERTA_BLOQUEADA`");
    expect(clmErrorCode(err)).toBe("COMPUERTA_BLOQUEADA");
  });

  it("ignora errores de Postgres que no son de negocio", () => {
    const err = new Error("Raw query failed. Code: `42501`. Message: `permission denied for table dossiers`");
    expect(clmErrorCode(err)).toBeNull();
  });
});

describe("transitionErrorFromCode", () => {
  it("clasifica permisos, conflictos y compuertas", () => {
    expect(transitionErrorFromCode("ROL_NO_AUTORIZADO")).toEqual({ kind: "PERMISO", code: "ROL_NO_AUTORIZADO" });
    expect(transitionErrorFromCode("CONFLICTO_DE_VERSION")).toEqual({ kind: "CONFLICTO_DE_VERSION" });
    const f = [{ check: "PAA_ALINEADO", hard: true, message: "x" }];
    expect(transitionErrorFromCode("COMPUERTA_BLOQUEADA", f)).toEqual({ kind: "COMPUERTA_BLOQUEADA", failures: f });
    expect(transitionErrorFromCode(null)).toEqual({ kind: "OTRO", code: "ERROR_DESCONOCIDO" });
  });
});
