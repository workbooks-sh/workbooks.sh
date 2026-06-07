// Ambient type declarations for @cloudflare/puppeteer.
// This package is available at runtime inside Cloudflare Workers when the
// [browser] binding is declared in wrangler.toml, but is NOT published to
// npm as a devDependency.  We declare the minimal surface we actually use
// so TypeScript accepts the dynamic import in fetch-brand.ts.
declare module "@cloudflare/puppeteer" {
  interface Page {
    setUserAgent(ua: string): Promise<void>;
    setDefaultNavigationTimeout(ms: number): void;
    goto(url: string, opts?: { waitUntil?: string }): Promise<unknown>;
    content(): Promise<string>;
    url(): string;
  }

  interface Browser {
    newPage(): Promise<Page>;
    close(): Promise<void>;
  }

  interface PuppeteerAPI {
    launch(binding: unknown): Promise<Browser>;
  }

  const puppeteer: PuppeteerAPI;
  export default puppeteer;
}
