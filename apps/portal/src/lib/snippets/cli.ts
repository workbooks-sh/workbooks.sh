import type { Verb } from "@brandnana/schema/verbs";

/**
 * Build a CLI snippet from verb.cliCommand + inputs.
 *
 * Heuristic:
 * - Inputs already represented as <arg> positionals in cliCommand → skip them.
 * - Remaining required inputs → positional appended after the command.
 * - Remaining optional inputs → --flag <value> style.
 */
export function cliSnippet(verb: Verb): string {
  const cmd = verb.cliCommand.join(" ");

  // Detect which input names are already positionally referenced in cliCommand.
  // We treat anything inside <...> in the template as a covered positional.
  const covered = new Set(
    [...cmd.matchAll(/<([^>]+)>/g)].map((m) => m[1]?.replace(/-/g, "_") ?? ""),
  );

  const remaining = verb.inputs.filter((i) => !covered.has(i.name));
  const required = remaining.filter((i) => i.required);
  const optional = remaining.filter((i) => !i.required);

  const parts: string[] = [cmd];

  for (const inp of required) {
    parts.push(`<${inp.name}>`);
  }
  for (const inp of optional) {
    const flag = `--${inp.name.replace(/_/g, "-")}`;
    if (inp.type === "boolean") {
      parts.push(`[${flag}]`);
    } else {
      parts.push(`[${flag} <${inp.name}>]`);
    }
  }

  return parts.join(" ");
}
