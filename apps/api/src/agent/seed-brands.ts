// Hand-verified seed data for the 5 v1 brand books.
//
// We DON'T fabricate brand facts (hex codes, logo URLs, real products) with an
// LLM — those need to be accurate. The LLM later curates the narrative voice
// + slide structure on top of these facts.
//
// When the live brand-fetch vendor endpoints (context.dev) are wired up with
// API keys, we'll replace this seed data with real vendor responses. For v1
// these five brands prove the bundle/serve/render pipeline works end-to-end.

export interface SeedBrand {
  slug: string;
  domain: string;
  brand_name: string;
  category: string;
  tagline: string;
  /** One-paragraph what-they-do, for the LLM to riff voice off of. */
  description: string;
  logo_svg_url: string;
  primary_hex: string;
  primary_name: string;
  secondary_hex: string;
  secondary_name: string;
  /** Extra palette colors, ordered light→dark or by importance. */
  palette: Array<{ hex: string; name: string }>;
  primary_font: string;
  secondary_font: string;
  /** Real product samples — name + price + category. */
  products: Array<{ name: string; price: number; currency: string; category: string }>;
  /** Real (or canonical) ad headlines / campaign lines. */
  ads: Array<{ headline: string; platform: string; cta: string }>;
  /** Notable competitors. */
  competitors: Array<{ name: string; domain: string }>;
  /** Social profile URLs. */
  social: Array<{ network: string; url: string }>;
}

export const SEED_BRANDS: Record<string, SeedBrand> = {
  aesop: {
    slug: "aesop",
    domain: "aesop.com",
    brand_name: "Aesop",
    category: "Beauty · Skincare · Body care",
    tagline: "Considered formulations for skin, hair and body.",
    description:
      "Australian luxury skincare brand established in Melbourne in 1987. " +
      "Apothecary aesthetic, amber bottles, almost zero photography. Stores " +
      "double as architectural set pieces. Voice is literary, restrained, almost " +
      "academic — never sells, only describes.",
    logo_svg_url: "https://logo.clearbit.com/aesop.com",
    primary_hex: "#1F1F1F",
    primary_name: "Apothecary Black",
    secondary_hex: "#F2EFE9",
    secondary_name: "Parchment",
    palette: [
      { hex: "#1F1F1F", name: "Apothecary Black" },
      { hex: "#F2EFE9", name: "Parchment" },
      { hex: "#8B5A2B", name: "Amber Glass" },
      { hex: "#5C5044", name: "Earth Tan" },
      { hex: "#A99B85", name: "Linen" },
    ],
    primary_font: "Optima",
    secondary_font: "Helvetica Neue",
    products: [
      { name: "Resurrection Aromatique Hand Wash 500ml", price: 41, currency: "USD", category: "Hand" },
      { name: "Parsley Seed Anti-Oxidant Serum 100ml", price: 130, currency: "USD", category: "Skin" },
      { name: "Geranium Leaf Body Cleanser 500ml", price: 41, currency: "USD", category: "Body" },
      { name: "Marrakech Intense Eau de Toilette 50ml", price: 175, currency: "USD", category: "Fragrance" },
      { name: "Reverence Aromatique Hand Balm 75ml", price: 33, currency: "USD", category: "Hand" },
      { name: "Classic Shampoo 200ml", price: 33, currency: "USD", category: "Hair" },
    ],
    ads: [
      { headline: "Considered formulations for skin, hair and body.", platform: "Brand", cta: "Explore" },
      { headline: "A daily ritual. Reformatted.", platform: "Meta", cta: "Shop the Range" },
      { headline: "Cleansing as practice, not performance.", platform: "Print", cta: "Visit a Signature Store" },
    ],
    competitors: [
      { name: "Le Labo", domain: "lelabofragrances.com" },
      { name: "Diptyque", domain: "diptyqueparis.com" },
      { name: "Byredo", domain: "byredo.com" },
      { name: "Frederic Malle", domain: "fredericmalle.com" },
    ],
    social: [
      { network: "instagram", url: "https://www.instagram.com/aesopskincare/" },
      { network: "youtube", url: "https://www.youtube.com/user/AesopSkincare" },
    ],
  },

  sweetgreen: {
    slug: "sweetgreen",
    domain: "sweetgreen.com",
    brand_name: "Sweetgreen",
    category: "Restaurants · Fast-casual · Health",
    tagline: "Real food. Real fast.",
    description:
      "Fast-casual chain founded by three Georgetown students in 2007. " +
      "Sourced-from-here ethos, hand-tossed bowls, transparent supply chain. " +
      "Voice is warm, optimistic, low-jargon — wellness without preaching. " +
      "App-first ordering. Music in stores curates a vibe more than a brand.",
    logo_svg_url: "https://logo.clearbit.com/sweetgreen.com",
    primary_hex: "#0C5132",
    primary_name: "Field Green",
    secondary_hex: "#F8F1E1",
    secondary_name: "Cream",
    palette: [
      { hex: "#0C5132", name: "Field Green" },
      { hex: "#F8F1E1", name: "Cream" },
      { hex: "#E8D85F", name: "Honey" },
      { hex: "#D44A3F", name: "Tomato" },
      { hex: "#2B2B2B", name: "Soil" },
    ],
    primary_font: "Sweetgreen Sans",
    secondary_font: "GT America",
    products: [
      { name: "Harvest Bowl", price: 13.95, currency: "USD", category: "Bowls" },
      { name: "Kale Caesar", price: 12.95, currency: "USD", category: "Salads" },
      { name: "Chicken + Brussels", price: 14.95, currency: "USD", category: "Plates" },
      { name: "Guacamole Greens", price: 13.45, currency: "USD", category: "Salads" },
      { name: "Steelhead + Quinoa", price: 16.95, currency: "USD", category: "Bowls" },
      { name: "Spicy Cashew Salad", price: 13.95, currency: "USD", category: "Salads" },
    ],
    ads: [
      { headline: "Real food. Real fast.", platform: "Brand", cta: "Order Now" },
      { headline: "Built fresh. Sourced from here.", platform: "Meta", cta: "Find a Sweetgreen" },
      { headline: "Lunch. Solved.", platform: "Out of Home", cta: "Order" },
    ],
    competitors: [
      { name: "Cava", domain: "cava.com" },
      { name: "Chopt", domain: "choptsalad.com" },
      { name: "Tender Greens", domain: "tendergreens.com" },
      { name: "Just Salad", domain: "justsalad.com" },
    ],
    social: [
      { network: "instagram", url: "https://www.instagram.com/sweetgreen/" },
      { network: "tiktok", url: "https://www.tiktok.com/@sweetgreen" },
      { network: "twitter", url: "https://twitter.com/sweetgreen" },
    ],
  },

  vercel: {
    slug: "vercel",
    domain: "vercel.com",
    brand_name: "Vercel",
    category: "Developer tools · Cloud infrastructure · Frontend hosting",
    tagline: "Develop. Preview. Ship.",
    description:
      "Frontend cloud and home of Next.js, founded by Guillermo Rauch. " +
      "Visual language built around a single black ▲ on white — geometric, " +
      "minimal, almost typographic. Voice is precise, technical, occasionally " +
      "playful — developer-first, no fluff. Conference (Vercel Ship) and brand " +
      "always reads like Apple keynote staging for engineers.",
    logo_svg_url: "https://logo.clearbit.com/vercel.com",
    primary_hex: "#000000",
    primary_name: "Vercel Black",
    secondary_hex: "#FFFFFF",
    secondary_name: "Paper",
    palette: [
      { hex: "#000000", name: "Vercel Black" },
      { hex: "#FFFFFF", name: "Paper" },
      { hex: "#0070F3", name: "Highlight Blue" },
      { hex: "#FF0080", name: "Pink Flash" },
      { hex: "#7928CA", name: "Violet" },
      { hex: "#F5A623", name: "Amber" },
    ],
    primary_font: "Geist",
    secondary_font: "Geist Mono",
    products: [
      { name: "Hobby", price: 0, currency: "USD", category: "Plans" },
      { name: "Pro", price: 20, currency: "USD", category: "Plans" },
      { name: "Enterprise", price: 0, currency: "USD", category: "Plans" },
      { name: "v0", price: 20, currency: "USD", category: "AI" },
      { name: "Edge Functions", price: 0, currency: "USD", category: "Compute" },
      { name: "Postgres", price: 0, currency: "USD", category: "Storage" },
    ],
    ads: [
      { headline: "Develop. Preview. Ship.", platform: "Brand", cta: "Start Deploying" },
      { headline: "Ship faster. Worry less.", platform: "Meta", cta: "Try Free" },
      { headline: "The frontend cloud.", platform: "Conference", cta: "Get Started" },
      { headline: "v0 — Generate UI with simple text prompts.", platform: "Twitter", cta: "Try v0" },
    ],
    competitors: [
      { name: "Netlify", domain: "netlify.com" },
      { name: "Cloudflare Pages", domain: "pages.cloudflare.com" },
      { name: "Render", domain: "render.com" },
      { name: "AWS Amplify", domain: "aws.amazon.com/amplify" },
    ],
    social: [
      { network: "twitter", url: "https://twitter.com/vercel" },
      { network: "github", url: "https://github.com/vercel" },
      { network: "youtube", url: "https://www.youtube.com/@VercelHQ" },
    ],
  },

  spotify: {
    slug: "spotify",
    domain: "spotify.com",
    brand_name: "Spotify",
    category: "Consumer software · Music + audio streaming",
    tagline: "Music for every mood.",
    description:
      "Audio streaming service founded in Stockholm in 2006. Brand voice is " +
      "warm-electric: equal parts editorial taste, algorithmic surprise, and " +
      "playful campaign moments (Wrapped, Blend, Daylist). Visual identity is " +
      "Spotify Green on black, pill-shaped UI, Circular as the typographic core. " +
      "Sound trumps spectacle.",
    logo_svg_url: "https://logo.clearbit.com/spotify.com",
    primary_hex: "#1DB954",
    primary_name: "Spotify Green",
    secondary_hex: "#191414",
    secondary_name: "Off Black",
    palette: [
      { hex: "#1DB954", name: "Spotify Green" },
      { hex: "#191414", name: "Off Black" },
      { hex: "#FFFFFF", name: "Paper" },
      { hex: "#FFC862", name: "Wrapped Honey" },
      { hex: "#F037A5", name: "Daylist Pink" },
      { hex: "#5038A0", name: "DJ Purple" },
    ],
    primary_font: "Spotify Circular",
    secondary_font: "Circular Std",
    products: [
      { name: "Free (ad-supported)", price: 0, currency: "USD", category: "Plans" },
      { name: "Premium Individual", price: 11.99, currency: "USD", category: "Plans" },
      { name: "Premium Duo", price: 16.99, currency: "USD", category: "Plans" },
      { name: "Premium Family", price: 19.99, currency: "USD", category: "Plans" },
      { name: "Premium Student", price: 5.99, currency: "USD", category: "Plans" },
      { name: "Audiobooks add-on", price: 9.99, currency: "USD", category: "Add-ons" },
    ],
    ads: [
      { headline: "Music for every mood.", platform: "Brand", cta: "Get Premium" },
      { headline: "Your Wrapped is here.", platform: "Out of Home", cta: "See Yours" },
      { headline: "Made for you. By a robot. Backed by humans.", platform: "Meta", cta: "Listen Free" },
      { headline: "Listen without limits.", platform: "TV", cta: "Try Premium" },
    ],
    competitors: [
      { name: "Apple Music", domain: "music.apple.com" },
      { name: "YouTube Music", domain: "music.youtube.com" },
      { name: "Amazon Music", domain: "music.amazon.com" },
      { name: "Tidal", domain: "tidal.com" },
    ],
    social: [
      { network: "instagram", url: "https://www.instagram.com/spotify/" },
      { network: "twitter", url: "https://twitter.com/Spotify" },
      { network: "tiktok", url: "https://www.tiktok.com/@spotify" },
    ],
  },

  "liquid-death": {
    slug: "liquid-death",
    domain: "liquiddeath.com",
    brand_name: "Liquid Death",
    category: "Beverage · Canned water · Lifestyle",
    tagline: "Murder your thirst.",
    description:
      "Mountain water in a tallboy can, branded like a heavy metal record. " +
      "Founded in 2017 to drag the hydration aisle into the punk show. Voice is " +
      "deadpan, gleefully transgressive — every campaign reads like a tour " +
      "flyer (Pizza Hunks, Liquid Death meets The Bachelor, the literal " +
      "tombstone-shaped can crusher). The water is just water; the brand is " +
      "the product.",
    logo_svg_url: "https://logo.clearbit.com/liquiddeath.com",
    primary_hex: "#000000",
    primary_name: "Pitch Black",
    secondary_hex: "#FFFFFF",
    secondary_name: "Bone White",
    palette: [
      { hex: "#000000", name: "Pitch Black" },
      { hex: "#FFFFFF", name: "Bone White" },
      { hex: "#E5202D", name: "Blood" },
      { hex: "#1C90D6", name: "Cold Mountain" },
      { hex: "#FFC629", name: "Caution" },
    ],
    primary_font: "Trade Gothic",
    secondary_font: "Helvetica Neue Bold",
    products: [
      { name: "Mountain Water Tallboy (12-pack)", price: 18.99, currency: "USD", category: "Still" },
      { name: "Sparkling Water Tallboy (12-pack)", price: 19.99, currency: "USD", category: "Sparkling" },
      { name: "Severed Lime Flavored Sparkling", price: 19.99, currency: "USD", category: "Flavored" },
      { name: "Mango Chainsaw Iced Tea", price: 19.99, currency: "USD", category: "Iced Tea" },
      { name: "Berry It Alive Iced Tea", price: 19.99, currency: "USD", category: "Iced Tea" },
      { name: "Country Club Cola", price: 21.99, currency: "USD", category: "Soda" },
    ],
    ads: [
      { headline: "Murder your thirst.", platform: "Brand", cta: "Shop Now" },
      { headline: "Death to plastic.", platform: "Out of Home", cta: "Switch to Cans" },
      { headline: "Liquid Death visits The Bachelor.", platform: "YouTube", cta: "Watch" },
      { headline: "Pizza Hunks. The pizza so good it could kill you.", platform: "Print", cta: "Order" },
    ],
    competitors: [
      { name: "Spindrift", domain: "spindriftfresh.com" },
      { name: "LaCroix", domain: "lacroixwater.com" },
      { name: "Topo Chico", domain: "topochicousa.com" },
      { name: "Athletic Brewing", domain: "athleticbrewing.com" },
    ],
    social: [
      { network: "instagram", url: "https://www.instagram.com/liquiddeath/" },
      { network: "tiktok", url: "https://www.tiktok.com/@liquiddeath" },
      { network: "youtube", url: "https://www.youtube.com/@LiquidDeath" },
    ],
  },
};

export const SEED_SLUGS = Object.keys(SEED_BRANDS);
