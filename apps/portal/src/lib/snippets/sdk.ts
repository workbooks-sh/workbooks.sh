import type { Verb } from "@brandnana/schema/verbs";

/** Map a verb id to a client method path, e.g. "brand.fetch" → "client.brand.fetch". */
function verbToMethodPath(id: string): string {
  return `client.${id}`;
}

/** Build the args object literal from verb inputs. */
function buildArgsObject(verb: Verb): string {
  if (verb.inputs.length === 0) return "";

  // Single-arg verbs that map to a positional string get passed directly, not as an object.
  // Heuristic: if verb has exactly one required string input AND the CLI command ends with <name>,
  // pass it as a positional, not an object.
  const requiredInputs = verb.inputs.filter((i) => i.required);
  const optionalInputs = verb.inputs.filter((i) => !i.required);

  if (requiredInputs.length === 1 && optionalInputs.length === 0) {
    const inp = requiredInputs[0];
    if (inp && inp.type === "string") {
      return `"<${inp.name}>"`;
    }
  }

  // Otherwise build an object literal.
  const lines = verb.inputs.map((inp) => {
    let val: string;
    if (inp.type === "string") val = `"<${inp.name}>"`;
    else if (inp.type === "number") val = "0";
    else if (inp.type === "boolean") val = "false";
    else if (inp.type.endsWith("[]")) val = "[]";
    else val = `"<${inp.name}>"`;

    const comment = inp.required ? "" : "  // optional";
    return `  ${inp.name}: ${val},${comment}`;
  });

  return `{\n${lines.join("\n")}\n}`;
}

export function sdkSnippet(verb: Verb): string {
  const method = verbToMethodPath(verb.id);
  const args = buildArgsObject(verb);

  return `import { BrandnanaClient } from "@brandnana/sdk";

const client = new BrandnanaClient({ apiKey: process.env.BRANDNANA_API_KEY });

const result = await ${method}(${args});
console.log(result);`;
}
