# Character Art Routes — C3CP → FBX → Blender toon cards

How we get the Artlix Studios "C3CP" characters (Fab listing `a8e1d67f-4d68-4abc-9e8b-5539056b1d67`;
folders C3CFC/C3CMC/C3CV1/C3CV2; `SKM_*_FULL_01..15`) into Blender as FBX for 2D card art (Addendum).

## Dead route — Unreal/Fab (do not revisit)
The Fab download is **uncooked uassets**: geometry exists only as editor-source `FbxSkeletalMeshImportData`,
no cooked render data → CUE4Parse/umodel can't extract, and Unreal itself needs ~50GB (we have 25GB free). Definitively dead.

## Key insight
C3C = Artlix's **"Customizable 3D Characters"** line, sold on the **Unity Asset Store** too (same studio, same meshes).
A `.unitypackage` is just **gzip+tar of the publisher's ORIGINAL source files** — the literal `.fbx` + `.png`, byte-for-byte —
not cooked engine data. So the Unity edition yields real FBX where the Unreal edition could not. Extraction needs **no Unity install**.

## Ranked routes to FBX

| # | Route | Cost | Effort | Confidence | My call |
|---|-------|------|--------|-----------|---------|
| 1 | **Email publisher** (`artlix.studios@gmail.com`) w/ Fab order ID, ask for FBX/glTF source | $0 | ~5 min + wait | Medium (small solo pub, often obliges verified owners) | **Do now, in parallel** |
| 2 | **Buy Unity SKU 259332** "Customizable 3D Characters Pack" → extract `.unitypackage` | ~$35 (50% Spring Sale, list $69.99) | ~30 min | High (~85% this SKU bundles source FBX; ~95% extraction works) | **Guaranteed fallback** |
| 2b | Cheaper Unity partials if cyberpunk/both vols not needed: base 253974 ($49.99), Vol 1 253976 ($39.99) | $40–50 | ~30 min | High, *if* SKM_*_FULL set is in that SKU | Only if budget-driven; verify Package Content tab |
| 2c | Superset bundle 295594 (Complete) — also bundles Sci-Fi/Survival/Cosmo we don't need | $149.99 | ~30 min | High | Skip — overkill |
| 3 | AssetRipper (mesh→FBX/GLB) | $0 tool | High | N/A here — reads *built games*, not source `.unitypackage` | Contingency only (serialized-mesh-only SKU); not expected |
| — | ArtStation / Sketchfab loose FBX | — | — | None found (403 store, no loose models) | Dead end |

## Extraction (no Unity, no Editor) — already built & tested
A `.unitypackage`→FBX extractor is **already built and tested at `/tmp`** (will move into repo `tools/` if this route is chosen).
Equivalent one-liners if needed: `tar -xzf C3CP.unitypackage -C raw/` then copy each GUID dir's `asset` to the path in its
`pathname` (filter `*.fbx`); or `pip install unitypackage-extractor && python -m unitypackage_extractor C3CP.unitypackage out/`.
FBX land at their original `Assets/...` paths; textures come out the same way. Then import straight into Blender for toon-shading.

## Recommendation
Run **Route 1 + Route 2 in parallel**. Email Artlix today (free, may save the re-buy). Simultaneously, before buying,
open SKU **259332**'s **"Package Content"** tab in a browser and confirm the `SKM_*_FULL_01..15` `.fbx` files are listed —
if yes, buy (~$35), download via Package Manager (caches to `~/Library/Unity/Asset Store-5.x/Artlix Studios/`), and extract.
Whichever returns FBX first wins; the Unity buy is the certain path. Move the `/tmp` extractor into `tools/` once committed.
