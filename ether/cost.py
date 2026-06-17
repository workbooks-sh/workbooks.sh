#!/usr/bin/env python3
"""Turn measured bitnet.cpp tok/s into $/M tokens at Fly per-second pricing,
and compare against the closest hosted reference.

Usage:
    python3 cost.py --machine-monthly 47.32 --pp 40 --tg 9
        pp = prefill tok/s (input), tg = generation tok/s (output)
"""
import argparse

# Fly bills per second; only while running. 730h/mo => 2,628,000 s.
SECONDS_PER_MONTH = 730 * 3600

# Hosted reference points (OpenRouter, June 2026). BitNet has no API competitor,
# so we compare to the cheapest small/mid open models someone runs on GPU.
REFERENCES = {
    "Phi-4 (14B)":          (0.065, 0.14),
    "Gemma 4 31B":          (0.12, 0.35),
    "Gemma 4 26B-A4B MoE":  (0.06, 0.33),
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--machine-monthly", type=float, required=True, help="Fly preset $/month")
    ap.add_argument("--pp", type=float, required=True, help="prefill (input) tok/s")
    ap.add_argument("--tg", type=float, required=True, help="generation (output) tok/s")
    ap.add_argument("--label", default="shared-cpu-8x/8GB")
    a = ap.parse_args()

    dps = a.machine_monthly / SECONDS_PER_MONTH  # dollars per second
    in_per_m = dps / a.pp * 1_000_000            # one stream, no batching
    out_per_m = dps / a.tg * 1_000_000

    print(f"\nFly {a.label}  (${a.machine_monthly}/mo = ${dps*1e6:.3f}/Msec)")
    print(f"  prefill {a.pp} tok/s  ->  ${in_per_m:.3f} / 1M input")
    print(f"  gen     {a.tg} tok/s  ->  ${out_per_m:.3f} / 1M output")
    print(f"\n  vs hosted (someone's GPU):")
    for name, (ri, ro) in REFERENCES.items():
        fi, fo = in_per_m / ri, out_per_m / ro
        verdict = "BEATS" if fo < 1 else f"{fo:.1f}x pricier"
        print(f"    {name:22s} in {fi:5.1f}x  out {fo:5.1f}x  ({verdict} on output)")

    # Break-even: how many concurrent streams (≈ batch) would close the gap to the
    # cheapest reference. CPU can't truly batch, but this frames the structural gap.
    cheapest_out = min(ro for _, ro in REFERENCES.values())
    print(f"\n  Gap to cheapest hosted output (${cheapest_out}/M): {out_per_m/cheapest_out:.1f}x")
    print(f"  Marginal cost if riding an already-paid sandbox: ~$0 (the real angle).\n")

if __name__ == "__main__":
    main()
