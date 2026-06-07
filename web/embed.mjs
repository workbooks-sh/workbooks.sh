// Client-side semantic embedder for a self-contained workbook — Model2Vec/potion
// static embeddings in ~100 lines of JS, mirroring host/embed/model2vec.ex
// byte-for-byte (same WordPiece, same mean-pool + L2). No model runtime, no
// network: tokenize → matrix lookup → mean-pool → normalize. So a workbook ships
// a small matrix + its precomputed chunk vectors and does SEMANTIC search in the
// browser, no server — the same "the files are the memory" model, client-side.
// Pairs with verify.mjs (the other browser-native workbook primitive).

// model = { vocab: Map<token,id>, unk: id, matrix: Float32Array(flat vocab*dim), dim }
export function loadModel(vocabText, matrixBuffer, dim) {
  const vocab = new Map();
  vocabText.split("\n").forEach((tok, i) => vocab.set(tok, i));
  return { vocab, unk: vocab.get("[UNK]") ?? 1, matrix: new Float32Array(matrixBuffer), dim };
}

export function embed(text, model) {
  const { dim, matrix } = model;
  const ids = tokenize(text, model);
  const acc = new Float64Array(dim);
  for (const id of ids) {
    const off = id * dim;
    for (let j = 0; j < dim; j++) acc[j] += matrix[off + j];
  }
  const n = ids.length || 1;
  for (let j = 0; j < dim; j++) acc[j] /= n;
  let norm = 0;
  for (let j = 0; j < dim; j++) norm += acc[j] * acc[j];
  norm = Math.sqrt(norm);
  if (norm > 0) for (let j = 0; j < dim; j++) acc[j] /= norm;
  return Array.from(acc);
}

export function cosine(a, b) {
  let d = 0;
  for (let i = 0; i < a.length; i++) d += a[i] * b[i];
  return d; // both are L2-normalized → dot = cosine
}

// Search precomputed chunk vectors: [{vec, ...meta}] → ranked by cosine to query.
export function search(query, chunks, model, k = 5) {
  const q = embed(query, model);
  return chunks
    .map((c) => ({ ...c, score: cosine(q, c.vec) }))
    .sort((a, b) => b.score - a.score)
    .slice(0, k);
}

// ── WordPiece (matches the Elixir tokenizer: unicode \w, ## continuation) ──────
function tokenize(text, model) {
  const out = [];
  const toks = text.toLowerCase().match(/[\p{L}\p{N}_]+|[^\p{L}\p{N}\s]/gu) || [];
  for (const t of toks) wordpiece(t, model, out);
  return out;
}

function wordpiece(word, model, out) {
  let chars = [...word];
  let first = true;
  while (chars.length) {
    let matched = null;
    for (let k = chars.length; k >= 1; k--) {
      const piece = (first ? "" : "##") + chars.slice(0, k).join("");
      if (model.vocab.has(piece)) { matched = [model.vocab.get(piece), k]; break; }
    }
    if (!matched) { out.push(model.unk); return; } // whole word → [UNK]
    out.push(matched[0]);
    chars = chars.slice(matched[1]);
    first = false;
  }
}
