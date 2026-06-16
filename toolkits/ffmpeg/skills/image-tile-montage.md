# ffmpeg — tile & slice images (grid montage, contact sheet, vertical chunks)
0.1.0
Use to combine N images into one grid (the tile filter), build a contact sheet, OR do the reverse — slice one tall image into N vertical chunks. Replaces the hand-rolled python png-slice loop with exact ffmpeg crop-per-chunk recipes.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Two opposite jobs:
  - *Compose* — lay several images into ONE grid image (a 2×2
    montage, a contact sheet of thumbnails, a side-by-side compare).
  - *Slice* — cut ONE tall image into N stacked chunks (review a long
    rendered page slide-by-slide for vision).

  ffmpeg is the image tool — *do not hand-roll a python/PIL loop*
  (that exact slice loop burned a Designer run). The slice recipe
  below is the ffmpeg replacement.

  NOT for: overlaying one image ON TOP of another with transparency
  ([image-overlay-composite](image-overlay-composite.md)); a single resize/crop
  ([image-resize](image-resize.md) / [image-crop-pad](image-crop-pad.md)).

# Compose — tile N images into a grid

  =tile=COLSxROWS= packs successive input frames into a grid. Feed
  the images as multiple `-i` inputs and combine via `filter_complex`,
  OR feed an image SEQUENCE (glob) and use `-vf`.

## From explicit inputs (small, fixed set)

## verify the inputs exist
```bash
  for f in "$@"; do test -f "$f" || { echo "missing: $f"; exit 1; }; done
```

## 4 images → 2×2 grid (order = -i order, row-major)
```bash
  ffmpeg -i a.png -i b.png -i c.png -i d.png -filter_complex "tile=2x2" grid.png
```

## 3 images stacked into a single column
```bash
  ffmpeg -i a.png -i b.png -i c.png -filter_complex "tile=1x3" column.png
```

  Cells with gaps + a background color:

## 2×2 grid, 10px outer margin, 5px gaps, white background
```bash
  ffmpeg -i a.png -i b.png -i c.png -i d.png \
    -filter_complex "tile=2x2:margin=10:padding=5:color=white" grid.png
```

## From a directory of images (contact sheet)

  `-pattern_type glob -i '*.png'` reads a whole directory as a frame
  sequence; then `-vf "scale`...,tile=CxR"= thumbnails each frame and
  tiles them. *Use `-2` (even) in the scale*, NOT `-1` — a `-1` that
  computes an ODD height makes `tile` silently fail to assemble the
  grid (you get a single cell back).

## contact sheet — thumbnail to 200px wide, 4 across
```bash
  ffmpeg -pattern_type glob -i 'shots/*.png' -vf "scale=200:-2,tile=4x3" sheet.png
```

  Pick COLS×ROWS ≥ your image count; extra cells fill with the tile
  background color. To auto-size rows for a known count N at C
  columns: `ROWS ` ceil(N / C)=.

## confirm the grid wrote + is a real image of the expected size
```bash
  test -f "$1" || { echo "output missing"; exit 1; }
  file "$1" | grep -qE "PNG|JPEG|WebP|AVIF" || { echo "not an image"; exit 1; }
  ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$1"
```

## Side-by-side / stacked via hstack / vstack (different sizes OK-ish)

  `tile` assumes uniform cells. For an explicit 2-up where you want
  full control, `hstack` (horizontal) / `vstack` (vertical) place
  inputs adjacent. Inputs must match on the shared dimension (same
  HEIGHT for hstack, same WIDTH for vstack) — scale first if not.

## before/after side by side (normalize height first)
```bash
  ffmpeg -i before.png -i after.png \
    -filter_complex "[0:v]scale=-2:600[l];[1:v]scale=-2:600[r];[l][r]hstack" compare.png
```

## 4-up grid via stacks (full manual control)
```bash
  ffmpeg -i a.png -i b.png -i c.png -i d.png \
    -filter_complex "[0:v][1:v]hstack[top];[2:v][3:v]hstack[bot];[top][bot]vstack" grid.png
```

# Slice — cut one TALL image into N vertical chunks

  The reverse of tiling: split a long page render into N stacked
  pieces so a vision model reads each at full resolution. Each chunk
  is one `crop` of full width × (height/N), offset by `i*(H/N)`. ffmpeg
  does ONE crop per call — loop in bash.

## verify input + read dims
```bash
  test -f "$1" || { echo "input file $1 not found"; exit 1; }
  ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$1"
```

## split a tall PNG into N stacked chunks (chunk-00.png …)
```bash
  IN=tall.png; N=4
  read -r W H < <(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$IN" | tr ',' ' ')
  CH=$(( H / N ))            # chunk height
  for i in $(seq 0 $((N-1))); do
    Y=$(( i * CH ))
    # last chunk: extend to the bottom so no rows are lost to rounding
    [ "$i" -eq $((N-1)) ] && CH=$(( H - Y ))
    ffmpeg -y -i "$IN" -vf "crop=${W}:${CH}:0:${Y}" "$(printf 'chunk-%02d.png' "$i")"
  done
```

  Split into a FIXED chunk HEIGHT instead of a fixed count — set
  `CH` directly and compute `N`:

## fixed 1200px-tall chunks (count derived from height)
```bash
  IN=tall.png; CH=1200
  read -r W H < <(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$IN" | tr ',' ' ')
  N=$(( (H + CH - 1) / CH ))     # ceil(H/CH)
  for i in $(seq 0 $((N-1))); do
    Y=$(( i * CH ))
    THIS=$(( H - Y < CH ? H - Y : CH ))   # last chunk may be shorter
    ffmpeg -y -i "$IN" -vf "crop=${W}:${THIS}:0:${Y}" "$(printf 'chunk-%02d.png' "$i")"
  done
```

  Horizontal slice (into vertical columns) is the same with W/X
  instead of H/Y: `crop`${CW}:${H}:${X}:0=.

## confirm every chunk wrote + is a real image
```bash
  for f in chunk-*.png; do
    file "$f" | grep -qE "PNG|JPEG|WebP|AVIF" || { echo "$f not an image"; exit 1; }
  done
  echo "✓ $(ls chunk-*.png | wc -l) chunks"
```

# Common pitfalls

  1. *Scale with `-1` before `tile` breaks the grid.* If `-1` computes
     an ODD dimension, `tile` produces a single cell instead of the
     grid. Always =scale=W:-2= (or `-2:H`) when feeding `tile`.
  2. *tile cell count vs image count.* COLS×ROWS smaller than the
     number of inputs DROPS the extras; larger leaves blank cells
     (filled with `color`). Size the grid to the count.
  3. *hstack/vstack dimension mismatch.* hstack needs equal HEIGHT,
     vstack equal WIDTH. Scale each input to the shared dimension
     first or ffmpeg errors.
  4. *Filter order for contact sheets.* `scale,tile` — scale runs
     per-frame BEFORE tiling. Putting tile first then scaling shrinks
     the whole sheet, not the cells.
  5. *Slice rounding drops bottom rows.* `H/N` truncates; the last
     chunk must take the remainder (`CH ` H - Y=) or you lose up to
     N-1 rows off the bottom.
  6. *Overwrite prompt in loops.* Pass `-y` so ffmpeg doesn't block on
     "overwrite?" for each chunk.
  7. *glob input order.* `-pattern_type glob` sorts lexically — pad
     numeric filenames (`img-001.png`) so `10` doesn't sort before `2`.

# Verification checklist

  - [ ] Compose: output dims == cols×cellW by rows×cellH (`ffprobe`)
  - [ ] Compose: all intended images present in the grid (eyeball)
  - [ ] Slice: chunk count == N (or ceil(H/CH))
  - [ ] Slice: last chunk reaches the bottom row (no dropped rows)
  - [ ] Every output `file` reports a real image type

# See also

  - [image-overlay-composite](image-overlay-composite.md) — layer images WITH transparency (not a grid)
  - [image-crop-pad](image-crop-pad.md) — the crop primitive the slice loop uses
  - [image-resize](image-resize.md) — the scale step in contact sheets
  - [image-ops](image-ops.md) — quick-start index for all image transforms
  - =ffmpeg -h filter=tile= / =-h filter=hstack= / =-h filter=vstack=
