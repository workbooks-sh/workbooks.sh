# CLIP sidecar — image + text embeddings (one cross-modal space)

A standalone embedder for the Workbooks runtime. CLIP maps **image and text into
one vector space**, so a text query retrieves images by meaning. It speaks the
generic `Workbooks.Embed.Http` contract, so the runtime connects with one env var.

It is deliberately **not baked into the engine image** — Node + transformers.js +
the model tripled build time and bloated the image. Run it where it makes sense
(a small box, a dev's machine, a second Fly process/machine) and point the runtime
at it.

## Run

```sh
cd runtime/sidecar/clip
npm install            # or: bun install
CLIP_PORT=8723 node server.mjs   # loads CLIP q8 (~150MB) on first start, then serves
```

## Connect the runtime

```sh
# image (+ cross-modal within the CLIP space); text stays whatever WB_EMBED is
export WB_EMBED_IMAGE="http:http://<clip-host>:8723/embed"
# OR one model for ALL modalities (text+image in one space):
export WB_EMBED_MULTIMODAL="http:http://<clip-host>:8723/embed"
```

## Contract

`POST /embed {"inputs": ["...", ...], "modality": "text"|"image"} -> {"vectors": [[...], ...]}`
— image inputs are url/path/base64; vectors are L2-normalized. Swap CLIP for a
bigger multimodal model (VLM2Vec on a GPU box) behind the same contract when a
capable machine is available (`Workbooks.Embed.Capability` recommends it).
