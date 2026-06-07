// Text-imported assets (`import x from "./f.css" with { type: "text" }`).
// Bun inlines the file as a string at build time; this types it for tsc.
declare module "*.css" {
  const content: string;
  export default content;
}
