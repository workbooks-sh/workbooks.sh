import { getVerb } from "@brandnana/schema/verbs";
import { error } from "@sveltejs/kit";
import type { PageLoad } from "./$types";

export const load: PageLoad = ({ params }) => {
  const verb = getVerb(params.id);
  if (!verb) {
    error(404, `Verb not found: ${params.id}`);
  }
  return { verb };
};
