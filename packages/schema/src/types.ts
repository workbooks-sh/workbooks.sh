// Source-of-truth TypeScript types matching sqlite.sql.
// Keep these in sync when the schema changes.

export type AdSource = "meta" | "tiktok" | "google" | "manual";
export type ProductPlatform =
  | "shopify"
  | "woocommerce"
  | "bigcommerce"
  | "squarespace"
  | "webflow"
  | "custom"
  | "unknown";

export interface Brand {
  id: string;
  domain: string;
  name: string | null;
  logo_url: string | null;
  palette_json: string | null;
  descriptors_json: string | null;
  fetched_at: number;
}

export interface Product {
  id: string;
  brand_id: string;
  external_id: string | null;
  url: string;
  title: string;
  description: string | null;
  price_cents: number | null;
  currency: string | null;
  available: number;
  platform: ProductPlatform;
  raw_json: string | null;
  first_seen_at: number;
  last_seen_at: number;
}

export interface ProductImage {
  id: string;
  product_id: string;
  url: string;
  alt: string | null;
  width: number | null;
  height: number | null;
  position: number;
}

export interface Ad {
  id: string;
  brand_id: string | null;
  source: AdSource;
  external_id: string;
  url: string | null;
  body: string | null;
  cta: string | null;
  first_seen_at: number;
  last_seen_at: number;
  raw_json: string | null;
}

export interface AdMedia {
  id: string;
  ad_id: string;
  kind: "image" | "video";
  url: string;
  poster_url: string | null;
  width: number | null;
  height: number | null;
}

export interface Page {
  id: string;
  brand_id: string | null;
  url: string;
  html_r2_key: string | null;
  fetched_at: number;
  status: number;
}

export interface SyncRun {
  id: string;
  kind: "ads" | "catalog" | "brand";
  source: string;
  brand_id: string | null;
  started_at: number;
  finished_at: number | null;
  ok: number;
  error: string | null;
}
