import { test, expect } from "bun:test";
import { imagePart, toDataUri } from "./image-input.js";

function mockFetch(status: number, contentType: string, body: BodyInit): typeof fetch {
  return (async () =>
    new Response(body, { status, headers: { "content-type": contentType } })) as unknown as typeof fetch;
}

test("toDataUri: passes an existing data URI through unchanged", async () => {
  const u = "data:image/png;base64,AAAA";
  expect(await toDataUri(u, mockFetch(200, "image/png", "x"))).toBe(u);
});

test("imagePart: inlines a fetched image as a base64 data URI", async () => {
  const p = await imagePart("https://r2.example/x.png", mockFetch(200, "image/png", new Uint8Array([1, 2, 3])));
  expect(p.type).toBe("image_url");
  expect(p.image_url.url.startsWith("data:image/png;base64,")).toBe(true);
});

test("imagePart: content-type guard — HTML viewer page falls back to the URL, NOT a fake image", async () => {
  const u = "https://tmpfiles.org/123/slide.png"; // serves an HTML viewer (text/html)
  const p = await imagePart(u, mockFetch(200, "text/html", "<html>viewer</html>"));
  expect(p.image_url.url).toBe(u); // not wrapped as data:image/png
});

test("imagePart: non-2xx fetch falls back to the plain URL", async () => {
  const u = "https://x.example/y.png";
  const p = await imagePart(u, mockFetch(404, "image/png", ""));
  expect(p.image_url.url).toBe(u);
});

test("imagePart: jpeg content-type yields a data:image/jpeg URI", async () => {
  const p = await imagePart("https://x/y.jpg", mockFetch(200, "image/jpeg", new Uint8Array([9, 9])));
  expect(p.image_url.url.startsWith("data:image/jpeg;base64,")).toBe(true);
});
