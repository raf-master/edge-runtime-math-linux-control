function bits(value: number): string {
  const buffer = new ArrayBuffer(8);
  new DataView(buffer).setFloat64(0, value, false);

  return Array.from(new Uint8Array(buffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

const constants = {
  E: Math.E,
  LN2: Math.LN2,
  LN10: Math.LN10,
  LOG2E: Math.LOG2E,
  LOG10E: Math.LOG10E,
  PI: Math.PI,
  SQRT1_2: Math.SQRT1_2,
  SQRT2: Math.SQRT2,
};

Deno.serve(() =>
  Response.json(
    Object.fromEntries(
      Object.entries(constants).map(([name, value]) => [
        name,
        {
          value: value.toPrecision(17),
          bits: bits(value),
        },
      ]),
    ),
  ),
);
