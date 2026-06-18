#!/usr/bin/env python3
"""Minimal OpenAI-compatible HTTP shim for the MLX diffusion model.

This is what makes the diffusion (GPU) lane a normal endpoint the Ether scheduler can POST to —
the lane is transport-agnostic, so once diffusion speaks /v1/chat/completions it joins the lanes
exactly like the llama-server AR lanes. Loads the model ONCE, then serves the masked-diffusion
generate loop from diffucoder_generate.

Run:   MODEL=mlx/DiffuCoder-7B-cpGRPO-4bit PORT=8085 python3 mlx/diffusion_server.py
Point the Ether GPU lane at:  http://127.0.0.1:8085/v1/chat/completions
"""
import os, sys, json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import mlx.core as mx
from mlx_lm import load

MODEL = os.environ.get("MODEL", "mlx/DiffuCoder-7B-cpGRPO-4bit")
PORT = int(os.environ.get("PORT", "8085"))
DEF_STEPS = int(os.environ.get("STEPS", "128"))
DEF_GEN = int(os.environ.get("GEN_LEN", "256"))

print(f"[server] loading {MODEL} ...", flush=True)
model, tokenizer = load(MODEL)
print(f"[server] ready on :{PORT}", flush=True)

def mask_id():
    cfg = os.path.join(MODEL, "config.json")
    if os.path.exists(cfg):
        c = json.load(open(cfg))
        if isinstance(c.get("mask_token_id"), int):
            return c["mask_token_id"]
    return getattr(tokenizer, "mask_token_id", None) or 151666

MASK = mask_id()

def forward(seq):
    h = model.model.embed_tokens(seq)
    for layer in model.model.layers:
        h = layer(h, None, None)                       # bidirectional
    h = model.model.norm(h)
    return (model.model.embed_tokens.as_linear(h) if getattr(model.args, "tie_word_embeddings", False)
            else model.lm_head(h))[0]

def generate(prompt_ids, gen_len, steps, eps=0.001):
    seq = list(prompt_ids) + [MASK] * gen_len
    plen = len(prompt_ids)
    ts = [1 + (eps - 1) * k / steps for k in range(steps + 1)]
    for i in range(steps):
        masked = [j for j in range(len(seq)) if seq[j] == MASK]
        if not masked:
            break
        logits = forward(mx.array([seq]))
        logits = mx.concatenate([logits[:1], logits[:-1]], axis=0)
        probs = mx.softmax(logits, axis=-1)
        conf = mx.max(probs, axis=-1); pred = mx.argmax(probs, axis=-1)
        mx.eval(conf, pred); conf, pred = conf.tolist(), pred.tolist()
        t, s = ts[i], ts[i + 1]
        n = len(masked) if i == steps - 1 else int(len(masked) * (1 - s / t))
        for j in sorted(masked, key=lambda j: conf[j], reverse=True)[:max(0, n)]:
            seq[j] = pred[j]
    return seq[plen:]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        msgs = body.get("messages", [])
        steps = int(body.get("steps", DEF_STEPS))
        gen_len = int(body.get("max_tokens", DEF_GEN))
        prompt_ids = tokenizer.apply_chat_template(msgs, add_generation_prompt=True)
        t0 = time.time()
        out = generate(prompt_ids, gen_len, steps)
        text = tokenizer.decode(out).split(tokenizer.eos_token)[0] if tokenizer.eos_token else tokenizer.decode(out)
        resp = {
            "choices": [{"message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
            "usage": {"completion_tokens": len(out)},
            "timings": {"predicted_per_second": round(len(out) / (time.time() - t0), 2)},
        }
        data = json.dumps(resp).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        self.wfile.write(data)

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
