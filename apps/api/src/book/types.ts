// Input types for the brand-book .org renderer.
//
// All fields are optional except the primary key fields (slug, brand_name,
// etc.) because real verb output is messy: some verbs may not return all
// fields depending on the brand's visibility and the plan tier.
// Renderers coerce undefined/null to empty string so templates stay clean.

// ── Brand ────────────────────────────────────────────────────────────────────

export interface ExtendedColor {
  name: string;
  hex: string;
}

export interface SocialHandle {
  network: string;
  handle: string;
  url: string;
}

export interface CaptureVerb {
  verb: string;
  ts: string;
  summary: string;
}

export interface BrandInput {
  brand_name: string;
  slug: string;
  domain: string;
  utc_iso?: string;
  version?: string;
  legal_name?: string;
  founded_year?: string | number;
  hq_city?: string;
  category?: string;
  tagline?: string;
  descriptors?: string[];
  voice_notes?: string;
  primary_hex?: string;
  primary_name?: string;
  secondary_hex?: string;
  secondary_name?: string;
  extended_colors?: ExtendedColor[];
  primary_font?: string;
  secondary_font?: string;
  mono_font?: string;
  logo_primary_url?: string;
  logo_on_light_url?: string;
  logo_on_dark_url?: string;
  logo_svg_path?: string;
  social?: SocialHandle[];
  capture_verbs?: CaptureVerb[];
}

// ── Competitor ───────────────────────────────────────────────────────────────

export interface AdRecord {
  ad_headline?: string;
  ad_id?: string;
  provider?: string;
  first_seen?: string;
  last_seen?: string;
  platform?: string;
  cta?: string;
  landing_url?: string;
  media_url?: string;
  media_type?: string;
  ad_body?: string;
  theme?: string;
  emotion?: string;
  hook?: string;
}

export interface CompetitorInput {
  competitor_name: string;
  brand_name: string;
  slug: string;
  domain: string;
  utc_iso?: string;
  category?: string;
  snapshot_notes?: string;
  palette_distance?: string | number;
  tone_delta?: string;
  delta_notes?: string;
  ads?: AdRecord[];
}

// ── Products ─────────────────────────────────────────────────────────────────

export interface ProductRecord {
  name: string;
  slug?: string;
  sku?: string;
  price?: string | number;
  currency?: string;
  sizes_csv?: string;
  colors_csv?: string;
  images_csv?: string;
  url?: string;
  stock_status?: string;
  materials_csv?: string;
  tags_csv?: string;
  category_path?: string;
  collection?: string;
  price_band?: string;
  description?: string;
}

export interface SubcategoryRecord {
  name: string;
  products?: ProductRecord[];
}

export interface CategoryRecord {
  name: string;
  subcategories?: SubcategoryRecord[];
  products?: ProductRecord[];
}

export interface CollectionRecord {
  name: string;
  products?: ProductRecord[];
}

export interface ColorIndexRecord {
  name: string;
  slug?: string;
  products?: ProductRecord[];
}

export interface PriceBandRecord {
  name: string;
  products?: ProductRecord[];
}

export interface StockGroupRecord {
  status: string;
  products?: ProductRecord[];
}

export interface ProductsInput {
  brand_name: string;
  utc_iso?: string;
  product_count?: string | number;
  category_count?: string | number;
  categories?: CategoryRecord[];
  collections?: CollectionRecord[];
  colors?: ColorIndexRecord[];
  price_bands?: PriceBandRecord[];
  stock_groups?: StockGroupRecord[];
}

// ── Timeline ─────────────────────────────────────────────────────────────────

export interface TimelineEvent {
  ts: string;
  verb_id: string;
  status: string;
  duration_ms?: string | number;
  vendor_cost_usd?: string | number;
  customer_charge_usd?: string | number;
  margin_usd?: string | number;
  summary?: string;
  error?: string;
}

export interface TimelineInput {
  brand_name: string;
  utc_iso?: string;
  events?: TimelineEvent[];
}
