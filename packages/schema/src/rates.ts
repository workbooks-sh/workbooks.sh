// Rate card types — vendor costs and customer pricing.
// Matches migrations-server/0005_rate_cards.sql.
//
// Immutability rule for CustomerRateCard:
//   tag=null  → untagged draft, freely mutable via proposeCustomerRate / update.
//   tag≠null  → frozen; never mutate in-place. To revise, insert a new row
//               (tagCustomerRate) with supersedes_id pointing at the old one.

export interface VendorRateCard {
  id: string;
  provider: string;
  model?: string | null;
  unit: 'token_input' | 'token_output' | 'request' | 'second' | 'image' | 'mb';
  price_usd_per_unit: number;
  effective_from: number;
  effective_to?: number | null;
  source: 'vendor_docs' | 'observed' | 'manual';
  notes?: string | null;
  created_at: number;
  created_by?: string | null;
}

export interface CustomerRateCard {
  id: string;
  tag?: string | null;                    // null = untagged draft (mutable)
  verb_id: string;                        // '*' for catch-all
  price_strategy: 'markup_multiplier' | 'fixed_per_call' | 'fixed_per_unit';
  markup_multiplier?: number | null;
  fixed_price_usd?: number | null;
  unit?: string | null;
  notes?: string | null;
  effective_from: number;
  supersedes_id?: string | null;
  created_at: number;
  created_by: string;
}
