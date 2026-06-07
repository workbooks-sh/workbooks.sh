# Image Generation Pipeline Notes

## API shape (verified empirically 2026-06-05)

**Endpoint:** `POST https://openrouter.ai/api/v1/chat/completions`
**Auth:** `Authorization: Bearer <key>` — key lives at `~/.config/openrouter/key` (read at runtime; never commit, never log).

### Request

```json
{
  "model": "openai/gpt-5.4-image-2",
  "messages": [{ "role": "user", "content": "<prompt>" }],
  "modalities": ["image", "text"]
}
```

The `modalities: ["image", "text"]` field is what enables image output through the
chat-completions endpoint. No other special params required.

### Response

Standard chat-completion envelope. The generated image arrives on the assistant
message as a base64 **data URL**:

```
.choices[0].message.images[0].image_url.url
  -> "data:image/png;base64,iVBORw0KGgo..."   (~1 MB of base64 for a 1024x1024 PNG)
```

- `message.content` is `null` for gpt-5.4-image-2 (no text caption alongside the image).
- `message.images[]` entries have `{ "type": "image_url", "image_url": { "url": "<data url>" } }`.
- The `model` echoed back is the dated snapshot, e.g. `openai/gpt-5.4-image-2-20260421`.
- Default output: 1024x1024 8-bit RGB PNG.

### Quirks / gotchas

- **Cost:** the probe call cost ~$0.22 (usage.cost), ~7k `image_tokens` in
  `completion_tokens_details`. Budget accordingly for batch exploration.
- **Latency:** generation takes on the order of a minute; use a generous curl
  timeout (`-m 300`).
- **Data URL prefix:** strip with a mime-agnostic regex (`^data:[^,]*,`) rather
  than hardcoding `data:image/png;base64,` — other models may return jpeg/webp.
- Decode with `base64 -d` (works on macOS as of Darwin 24).
- **BSD mktemp:** `/usr/bin/mktemp` rejects templates with a suffix after the
  `XXXXXX` ("mkstemp failed ... File exists"). Keep the X's trailing
  (`mktemp /tmp/foo.XXXXXX`, not `mktemp /tmp/foo.XXXXXX.json`). Fixed in
  gen.sh 2026-06-05.

## Tooling

`tools/gen.sh <subdir> <name> "<prompt>"` writes
`design/art-explorations/<subdir>/<name>.png`.

- Primary model: `openai/gpt-5.4-image-2` (3 attempts with backoff).
- Fallback: `google/gemini-3.1-flash-image-preview` — if the fallback is ever
  used, gen.sh appends a dated line to this file automatically.
- Fails loudly with the API response body on error (response bodies contain no
  auth material; the key is never echoed).
- Validates PNG magic bytes before reporting success.

- **gen.sh is NOT concurrency-safe (2026-06-05):** macOS `mktemp` does not
  substitute non-trailing `X`s, so the template `/tmp/gen-or-resp.XXXXXX.json`
  is created as a *literal* file. The first invocation grabs it; any parallel
  invocation dies immediately with `mkstemp failed ... File exists`. Run
  gen.sh invocations strictly sequentially (the EXIT trap removes the file).

## Validation

- 2026-06-05: `gen.sh _test probe "...copper frying pan mascot..."` →
  `_test/probe.png`, 1,167,676 bytes, valid 1024x1024 PNG, primary model used
  (no fallback needed).
