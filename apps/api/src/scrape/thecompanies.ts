// The Companies API wrapper — firmographic enrichment from a domain.
//
// Consumes env.THE_COMPANIES_API_KEY (thecompaniesapi.com). Backs the
// GET /brand/:domain/company verb: given a domain we return a single
// normalised Company record (name, industry, NAICS/SIC, employee range,
// HQ location, founded year, socials, logo) the director uses to colour
// the brand book with real firmographics instead of guesses.
//
// Docs:  https://www.thecompaniesapi.com/api/enrich-company-from-domain
// Auth:  Authorization: "Basic <TOKEN>" — note this is the literal token
//        after "Basic ", NOT standard base64(token:) HTTP Basic. Their
//        auth doc is explicit about this.
// Endpoint: GET https://api.thecompaniesapi.com/v2/companies/:domain
//   - 1 credit per enrichment, no charge if the company isn't found.
//   - 404 ⇒ unknown domain (we surface that as `null`, not an error).
//
// The raw upstream call is cached 24h per (tenant, domain) by vendorFetch;
// firmographics change slowly. Rate limited to 30/min/tenant.

import type { Bindings } from "../env.js";
import { vendorFetch } from "../vendor.js";
import { valyuSearch } from "./valyu.js";

const BASE = "https://api.thecompaniesapi.com/v2";

/**
 * Normalised firmographic record returned to the CLI / director. This is
 * a deliberately small projection of The Companies API's ~80-field
 * CompanyV2 response — only the fields the brand book actually consumes.
 */
export interface Company {
  /** Display name (about.name). */
  name: string | null;
  /** Canonical domain echoed back (domain.domain ?? requested domain). */
  domain: string;
  /** Short company description (descriptions.primary ?? tagline). */
  description: string | null;
  /** Tagline / one-liner (descriptions.tagline). */
  tagline: string | null;
  /** Primary industry label (about.industry). */
  industry: string | null;
  /** NAICS classification codes (codes.naics). */
  naics: string[];
  /** SIC classification codes (codes.sic). */
  sic: string[];
  /** Employee headcount bucket, e.g. "11-50" (about.totalEmployees). */
  employeeRange: string | null;
  /** Exact headcount when known (about.totalEmployeesExact). */
  employeeCount: number | null;
  /** HQ country name (locations.headquarters.country.name). */
  country: string | null;
  /** HQ city name (locations.headquarters.city.name). */
  city: string | null;
  /** Year the company was founded (about.yearFounded). */
  founded: number | null;
  /** Annual revenue band when published (finances.revenue). */
  revenue: string | null;
  /** Social profile URLs, keyed by network. Only present networks included. */
  socials: Partial<Record<SocialNetwork, string>>;
  /** Square logo URL (assets.logoSquare.src). */
  logo: string | null;
}

type SocialNetwork =
  | "linkedin"
  | "twitter"
  | "facebook"
  | "instagram"
  | "youtube"
  | "tiktok";

const SOCIAL_NETWORKS: readonly SocialNetwork[] = [
  "linkedin",
  "twitter",
  "facebook",
  "instagram",
  "youtube",
  "tiktok",
];

// Minimal structural typing of the upstream CompanyV2 response — only the
// nested paths we read. Everything is optional: the API omits empty fields.
interface SocialEntry {
  url?: string | null;
}

interface CompanyV2Response {
  domain?: { domain?: string | null } | null;
  about?: {
    name?: string | null;
    industry?: string | null;
    totalEmployees?: string | null;
    totalEmployeesExact?: number | null;
    yearFounded?: number | null;
  } | null;
  descriptions?: {
    primary?: string | null;
    tagline?: string | null;
  } | null;
  codes?: {
    naics?: string[] | null;
    sic?: string[] | null;
  } | null;
  locations?: {
    headquarters?: {
      city?: { name?: string | null } | null;
      country?: { name?: string | null } | null;
    } | null;
  } | null;
  finances?: {
    revenue?: string | null;
  } | null;
  assets?: {
    logoSquare?: { src?: string | null } | null;
  } | null;
  socials?: Partial<Record<SocialNetwork, SocialEntry | null>> | null;
}

export interface FetchCompanyOptions {
  domain: string;
  /** Tenant doing the call — per-tenant cache + rate-limit namespacing. */
  tenant: string;
  ctx?: ExecutionContext;
}

function normalise(domain: string, raw: CompanyV2Response): Company {
  const socials: Partial<Record<SocialNetwork, string>> = {};
  for (const net of SOCIAL_NETWORKS) {
    const url = raw.socials?.[net]?.url;
    if (typeof url === "string" && url.length > 0) socials[net] = url;
  }
  return {
    name: raw.about?.name ?? null,
    domain: raw.domain?.domain ?? domain,
    description: raw.descriptions?.primary ?? raw.descriptions?.tagline ?? null,
    tagline: raw.descriptions?.tagline ?? null,
    industry: raw.about?.industry ?? null,
    naics: raw.codes?.naics ?? [],
    sic: raw.codes?.sic ?? [],
    employeeRange: raw.about?.totalEmployees ?? null,
    employeeCount: raw.about?.totalEmployeesExact ?? null,
    country: raw.locations?.headquarters?.country?.name ?? null,
    city: raw.locations?.headquarters?.city?.name ?? null,
    founded: raw.about?.yearFounded ?? null,
    revenue: raw.finances?.revenue ?? null,
    socials,
    logo: raw.assets?.logoSquare?.src ?? null,
  };
}

/**
 * Fetch firmographics for a domain. Returns `null` when the company is
 * unknown to the provider (HTTP 404) — that's a normal "no data" result,
 * not a failure. Throws if the key isn't configured or the upstream
 * errors for any other reason (the route surfaces those as 502/503).
 */
export async function fetchCompany(
  env: Bindings,
  opts: FetchCompanyOptions,
): Promise<Company | null> {
  if (!env.THE_COMPANIES_API_KEY) {
    throw new Error("THE_COMPANIES_API_KEY is not configured on the worker");
  }
  const url = `${BASE}/companies/${encodeURIComponent(opts.domain)}`;
  const res = await vendorFetch(env, {
    provider: "thecompaniesapi",
    tenant: opts.tenant,
    url,
    method: "GET",
    headers: {
      // NOT base64 Basic — the provider expects the raw token after "Basic ".
      authorization: `Basic ${env.THE_COMPANIES_API_KEY}`,
    },
    cacheTtl: 86_400, // 24h — firmographics change slowly
    rateLimit: 30,
    metadata: { domain: opts.domain },
    ctx: opts.ctx,
  });
  // Unknown domain — provider doesn't bill these. Treat as "no data".
  if (res.status === 404) return null;
  if (!res.ok) {
    throw new Error(`thecompaniesapi ${res.status}: ${await res.text()}`);
  }
  const raw = (await res.json()) as CompanyV2Response;
  return normalise(opts.domain, raw);
}

// ── Valyu firmographic backfill ──────────────────────────────────────────────
//
// The Companies API frequently returns null for the high-value firmographics
// (founded year, HQ city/country, headcount, revenue band). Those facts are
// public web knowledge, so when a field is null we ask Valyu for the brand and
// scrape the answer out of the snippets. This is best-effort enrichment: we
// only ever FILL nulls, never overwrite a value the provider already returned,
// and a miss leaves the field null (a truthful "we don't know"), never throws.

export interface CompanyBackfill {
  /** The company record with previously-null firmographic fields filled where
   *  Valyu could resolve them. Non-firmographic fields are untouched. */
  company: Company;
  /** Which fields we successfully backfilled (for provenance). */
  filled: Array<keyof Company>;
  /** Fields we tried but couldn't resolve from Valyu. */
  unresolved: Array<keyof Company>;
  /** Non-fatal issues (e.g. Valyu key missing, search threw). */
  warnings: string[];
}

const YEAR_RE = /\b(1[6-9]\d{2}|20[0-2]\d)\b/;
const FOUNDED_RE = /\b(?:founded|established|est\.?|since)\b[^0-9]{0,24}(1[6-9]\d{2}|20[0-2]\d)/i;
const EMPLOYEES_RE = /([\d,]{2,})\+?\s*(?:employees|staff|people|team members)/i;
const REVENUE_RE = /(?:revenue|annual sales|turnover)[^$€£0-9]{0,16}([$€£]\s?[\d.,]+\s?(?:billion|million|bn|m|b|k)?)/i;
const HQ_RE = /(?:headquarter(?:ed|s)?|based|located|hq)\b[^.]{0,40}?\bin\b\s+([A-Z][A-Za-z.\-' ]+(?:,\s*[A-Z][A-Za-z.\-' ]+){0,2})/;

function corpus(results: { title: string; content?: string }[]): string {
  return results.map((r) => `${r.title}. ${r.content ?? ""}`).join("\n").slice(0, 8000);
}

/**
 * Fill null firmographic fields on a Company record using Valyu web search.
 * `base` may be null (provider had no record at all) — we synthesise a bare
 * Company keyed on `domain` and try to populate it. Always resolves; failures
 * are recorded in `warnings`.
 */
export async function backfillCompanyFirmographics(
  env: Bindings,
  args: {
    base: Company | null;
    domain: string;
    brandName: string;
    tenant: string;
    ctx?: ExecutionContext;
  },
): Promise<CompanyBackfill> {
  const company: Company = args.base ?? {
    name: args.brandName || null,
    domain: args.domain,
    description: null,
    tagline: null,
    industry: null,
    naics: [],
    sic: [],
    employeeRange: null,
    employeeCount: null,
    country: null,
    city: null,
    founded: null,
    revenue: null,
    socials: {},
    logo: null,
  };

  const filled: Array<keyof Company> = [];
  const unresolved: Array<keyof Company> = [];
  const warnings: string[] = [];

  // Only the firmographic fields the design doc calls out (founded / HQ /
  // employees / revenue). If they're all already present, skip the search.
  const needFounded = company.founded == null;
  const needHq = company.country == null && company.city == null;
  const needEmployees = company.employeeCount == null && company.employeeRange == null;
  const needRevenue = company.revenue == null;
  if (!needFounded && !needHq && !needEmployees && !needRevenue) {
    return { company, filled, unresolved, warnings };
  }
  if (!env.VALYU_API_KEY) {
    warnings.push("valyu backfill skipped: VALYU_API_KEY not configured");
    if (needFounded) unresolved.push("founded");
    if (needHq) unresolved.push("country");
    if (needEmployees) unresolved.push("employeeCount");
    if (needRevenue) unresolved.push("revenue");
    return { company, filled, unresolved, warnings };
  }

  const brand = args.brandName || company.name || args.domain;
  let text = "";
  try {
    const res = await valyuSearch(env, {
      query: `${brand} (${args.domain}) company founded headquarters number of employees annual revenue`,
      numResults: 8,
      tenant: args.tenant,
      ctx: args.ctx,
    });
    text = corpus(res.results);
  } catch (e) {
    warnings.push(`valyu backfill search failed: ${(e as Error).message}`);
    return { company, filled, unresolved, warnings };
  }

  if (needFounded) {
    const m = text.match(FOUNDED_RE) ?? text.match(YEAR_RE);
    const yr = m ? parseInt(m[1] ?? m[0], 10) : NaN;
    if (Number.isFinite(yr) && yr >= 1600 && yr <= new Date().getFullYear()) {
      company.founded = yr;
      filled.push("founded");
    } else {
      unresolved.push("founded");
    }
  }
  if (needHq) {
    const m = text.match(HQ_RE);
    if (m?.[1]) {
      const parts = m[1].split(",").map((s) => s.trim()).filter(Boolean);
      company.city = parts[0] ?? null;
      company.country = parts[parts.length - 1] ?? null;
      filled.push("city");
    } else {
      unresolved.push("country");
    }
  }
  if (needEmployees) {
    const m = text.match(EMPLOYEES_RE);
    const n = m?.[1] ? parseInt(m[1].replace(/,/g, ""), 10) : NaN;
    if (Number.isFinite(n) && n > 0) {
      company.employeeCount = n;
      filled.push("employeeCount");
    } else {
      unresolved.push("employeeCount");
    }
  }
  if (needRevenue) {
    const m = text.match(REVENUE_RE);
    if (m?.[1]) {
      company.revenue = m[1].replace(/\s+/g, " ").trim();
      filled.push("revenue");
    } else {
      unresolved.push("revenue");
    }
  }

  return { company, filled, unresolved, warnings };
}
