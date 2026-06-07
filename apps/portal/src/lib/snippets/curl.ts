import type { Verb } from "@brandnana/schema/verbs";

/** Build a JSON body skeleton from the verb's required+optional POST inputs. */
function buildJsonBody(verb: Verb): string {
  const bodyInputs = verb.inputs.filter((i) => i.name !== "domain" || verb.httpMethod === "POST");
  if (bodyInputs.length === 0) return "{}";

  const lines = bodyInputs.map((input) => {
    let val: string;
    if (input.type === "string") val = `"<${input.name}>"`;
    else if (input.type === "number") val = "0";
    else if (input.type === "boolean") val = "false";
    else if (input.type.endsWith("[]")) val = "[]";
    else val = `"<${input.name}>"`;
    return `    "${input.name}": ${val}`;
  });

  return `{\n${lines.join(",\n")}\n  }`;
}

/** Build a query-string form from GET inputs (excluding path params). */
function buildQueryString(verb: Verb, pathParams: Set<string>): string {
  const qInputs = verb.inputs.filter((i) => !pathParams.has(i.name));
  if (qInputs.length === 0) return "";
  return qInputs
    .map((i) => `  --data-urlencode "${i.name}=<${i.name}>"`)
    .join(" \\\n");
}

/** Extract {param} names from a path template. */
function extractPathParams(httpPath: string): Set<string> {
  const matches = httpPath.matchAll(/\{(\w+)\}/g);
  return new Set([...matches].map((m) => m[1]));
}

/** Fill path params with placeholder values. */
function fillPath(httpPath: string): string {
  return httpPath.replace(/\{(\w+)\}/g, "<$1>");
}

export function curlSnippet(verb: Verb, apiKey?: string): string {
  const key = apiKey ?? "YOUR_API_KEY";
  const base = "https://api.brandnana.net";
  const path = fillPath(verb.httpPath);
  const url = `${base}${path}`;
  const pathParams = extractPathParams(verb.httpPath);

  if (verb.httpMethod === "GET") {
    const qs = buildQueryString(verb, pathParams);
    const lines = [
      `curl -G ${url} \\`,
      `  -H "Authorization: Bearer ${key}"`,
    ];
    if (qs) lines.push(qs);
    return lines.join(" \\\n");
  }

  // POST / PATCH / DELETE with body
  const body = buildJsonBody(verb);
  return [
    `curl -X ${verb.httpMethod} ${url} \\`,
    `  -H "Authorization: Bearer ${key}" \\`,
    `  -H "Content-Type: application/json" \\`,
    `  -d '${body}'`,
  ].join(" \\\n");
}
