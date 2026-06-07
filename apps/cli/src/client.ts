import { type BrandnanaClient, createBrandnanaClient } from "@brandnana/sdk";
import { getApiKey } from "./keychain.js";

const ENV_BASE_URL = "BRANDNANA_BASE_URL";
const ENV_API_KEY = "BRANDNANA_API_KEY";
const DEFAULT_BASE_URL = "https://brandnana-api.shane-6d4.workers.dev";

export async function clientFromEnv(overrideBaseUrl?: string): Promise<BrandnanaClient> {
  const apiKey = process.env[ENV_API_KEY] ?? (await getApiKey());
  if (!apiKey) {
    throw new Error(`No API key found. Run \`brandnana login\` to sign in, or set ${ENV_API_KEY}.`);
  }
  return createBrandnanaClient({
    baseUrl: overrideBaseUrl ?? process.env[ENV_BASE_URL] ?? DEFAULT_BASE_URL,
    apiKey,
  });
}

export function baseUrlFromEnv(overrideBaseUrl?: string): string {
  return (overrideBaseUrl ?? process.env[ENV_BASE_URL] ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
}
