# Nexus Economics: Synthesis Report

*Hosted container-per-tenant "nexus" model. Date: 2026-06-14. All host prices as-of the same date; flag where they drift. **Fly pricing re-verified 2026-06-14 against `fly.io/docs/about/pricing`** — shared-cpu-1x $2.02/$3.32/$5.92/$11.11 per mo (256MB/512MB/1GB/2GB), stopped = $0 CPU/RAM + $0.15/GB-mo rootfs, volumes $0.15/GB-mo (billed when stopped), egress $0.02/GB NA·EU — all confirmed accurate.*

---

## 1. Nexus sizing & trim plan

### Measured shipped image (2026-06-14, from the registry manifests)

- **`ghcr.io/workbooks-sh/runtime:latest` — 329 MB compressed** (largest layer ~104 MB = the compiler toolchain). This is the actual hosted-nexus image. Uncompressed rootfs ≈ ~0.85 GB — that is the figure Fly's `$0.15/GB` parked-storage charge bills against; the 329 MB compressed drives registry storage + cold-start pull bandwidth.
- `bn-engine-agents` (brandnana engine variant already deployed on Fly) — 238 MB compressed.

**Cost reading:** at ~0.85 GB rootfs, parked storage ≈ **~$0.13/tenant/mo** — a rounding error next to the ~$1.30–1.75 compute floor (§2). Image size is far more a **cold-start-speed** lever than a cost lever.

### Local working-tree size breakdown (uncompressed `du` — NOT the shipped image)

> ⚠️ The figures below are on-disk `du` of the dev working tree (accumulated compile caches + the provisioned toolchain scratch). They rank trim *levers* but are **not what ships** — the clean CI image is the 329 MB measured above. An earlier draft's "~1.3–1.5 GB image" / "−766 MB saved" framing conflated this local `du` with the image size; corrected here.

| Component | Size | Per-tenant? | Trimmable? |
|---|---|---|---|
| **compilers-dist** (full toolchain) | **614 MB** | Yes (baked in every image) | **Externalize entirely** |
| └ zig lane | 279 MB | — | of which lib/libc multi-target = 170 MB prunable |
| └ rust/mrustc lane | 148 MB | — | ~101 MB build tree, partly prunable |
| └ clang lane | 104 MB | — | required if kept |
| └ go(yaegi) | 38 MB | — | |
| └ js + esbuild | 44 MB | — | |
| **build/commands** (accidental scratch) | **424 MB** | Yes — leaking | **~421 MB removable now** |
| └ required jq.wasm + grep.wasm | 3.5 MB | keep | |
| wasmtime binary | 46 MB | Yes | **No — core isolation, stays** |
| BEAM/ERTS + OTP + debian-slim base | ~150–250 MB *(est, low-confidence)* | Yes | mostly fixed |
| baked embedding model (potion-base-8M) | ~30 MB | Yes | small win, defer |
| wasm-tools.wasm + oql.wasm | ~11.4 MB | Yes | required kernel |
| **Total (uncompressed, est.)** | **~1.3–1.5 GB** | | |

### Ranked trim levers (biggest first)

1. **Externalize the compiler toolchain → shared build service: −614 MB.** The toolchain is *already* a standalone OCI layer (`ci/Dockerfile.compilers` → `ghcr.io/workbooks-sh/compilers`) but is still `COPY --from=compilers` into the runtime image. Running a compiled `.wasm` needs only **wasmtime**, never the compilers. Pull it out of the per-tenant image and run **one shared compiler/build service per node or per cluster** that emits content-addressed `.wasm` artifacts.
2. **Exclude `build/cache` + `build/commands` scratch from the build context (defensive hygiene). DONE — root `.dockerignore` scope, commit `7e083d80`.** The dev working tree accumulates a big compile cache (~766 MB on this box) and `COPY runtime/ .` + `COPY --from=build /app/build ./build` *would* carry it in if present — but a clean CI build starts with an empty cache, so the **measured 329 MB image was not actually carrying it.** This is leak-prevention (and matters for local deploy-kit builds), **not** a ~400 MB production cut. Keep it; don't overstate it.
3. **Prune zig lib/libc to wasm32-wasi only: −~120–150 MB** *(medium-confidence; needs a build smoke test — the wasi driver may lazily reference other-target libc).* Only relevant if the toolchain stays node-local rather than fully externalized.
4. **Audit rust/mrustc build tree: up to −~80 MB** of C++ source/intermediates beyond the libstd link objects the linker needs *(medium-confidence)*.
5. **Lazy-fetch the potion embedder: −30 MB.** Noted per instruction — small relative to the above. Move to a shared volume only after the big wins land. Heavy CLIP path is already opt-in (`WB_CLIP=1`), correctly excluded.

### Shared-build-service externalization plan + isolation guarantee

The clean seam already exists: `BuildBroker` compiles **entirely in-sandbox, no-network/no-fs by default**, content-addressed in/out, tenant-agnostic. The plan:

- A pool of build nodes owns the 614 MB toolchain; per-tenant runtime images carry only wasmtime + BEAM + baked jq/grep.
- Build → run delivery is just a file transfer of the `.wasm` into the tenant's `CommandRegistry`.

**Isolation guarantee the design MUST preserve** (founder's lock: shared build OK *only if runtime stays isolated*):
- **(a)** Running compiled wasm is isolated by per-tenant wasmtime instances *regardless of where the wasm was built* — the run wall is unchanged.
- **(b)** No tenant secrets enter a shared compile. `BuildBroker`'s no-network/no-fs default must be **guaranteed for the BROKER variant too**; per-tenant `NetGuard` principal + allow-list + rate must thread through any build that needs egress.
- **(c)** Build inputs/outputs stay content-addressed (cacheable, tenant-agnostic).
- **(d)** The shared builder must be sized for the spike profile (multi-hundred-MB to >1 GB per concurrent Rust/C compile) and **queue/pool compiles** to bound contention/DoS — the main risk of sharing.

### Target slimmed size

**Measured baseline: 329 MB compressed / ~0.85 GB uncompressed rootfs.** The only large *shipped* lever left is externalizing the compiler toolchain (~104 MB compressed / 614 MB uncompressed) → takes the image to ~225 MB compressed / ~0.24 GB rootfs, cutting Fly parked storage from ~$0.13 to ~$0.04/tenant/mo and roughly halving cold-start page-in. The scratch and embed-model trims are hygiene/marginal against the *measured* image (their GB-scale deltas were local `du`, never in the shipped image). Net: image size is a cold-start-speed win, not a material cost lever — see §2.

---

## 2. Per-tenant cost floor

### Assumptions (stated explicitly)

- **Idle footprint:** BEAM-bounded, **estimate 80–200 MB RSS** (no measured baseline in-repo — §7/§8 flag this as low-confidence). The team sizes a tenant to a **1 GB / 1 shared-vCPU** Fly VM for spike headroom, not steady state.
- **Active footprint:** spikes driven by in-sandbox compiles (a Rust/C compile transiently uses hundreds of MB → >1 GB wasm linear memory) — **but with the toolchain externalized (§1), most heavy compile memory moves OFF the tenant node onto the shared builder.** A tenant doing agent runs is network-bound, not RAM-heavy.
- **Disk:** slimmed image ~0.7–0.9 GB + a small data volume (Fly default 10 GB referenced, but real tenant data is small; blobs go to R2 per §4).
- **Scale-to-zero:** idle tenants hibernate; only a fraction are active at once. I model an illustrative **20% concurrent-active** fleet (i.e., 1 GB always-on cost is paid for ~20% of tenants' time; the rest pay only parked-storage).
- These are **cost floors (our COGS)**, not prices.

### Fly.io (native scale-to-zero — strongest fit)

Stopped/suspended Machines incur **zero CPU/RAM charge**; you pay only **$0.15/GB-rootfs/mo** while parked.
- Always-on 1 GB Machine = **$5.92/mo**; 512 MB = $3.32; 256 MB = $2.02.
- Parked rootfs for a ~0.8 GB slimmed image ≈ **$0.12/mo**.
- **Per-tenant floor @ 20% active on a 1 GB shape:** `0.20 × $5.92 + 0.80 × $0.12 ≈ $1.18 + $0.10 = ~$1.28/mo`.
- Add a per-tenant Fly **Volume** *only if stateful*: $0.15/GB/mo, **billed even when stopped, and host-pins the Machine.** A 3 GB volume = $0.45/mo. Avoid volumes by pushing state to R2/Tigris (§4) → keeps the floor at ~$1.28.
- **Fly per-tenant floor: ~$1.30–$1.75/mo** depending on volume.

### Hetzner (no native scale-to-zero — you build packing)

No per-machine hibernation billing; you **bin-pack many tenant containers onto one cheap server** and the "scale-to-zero" is logical (idle containers consume ~0 CPU and their RSS). Cost = server price ÷ tenants packed.
- **CX23** (2 vCPU / 4 GB / 40 GB, 20 TB egress) = €3.99 ≈ **$4.99/mo**. With 80–200 MB idle RSS, 4 GB packs ~15–25 mostly-idle tenants (RAM-bound; leave headroom for bursts) → **$0.20–$0.33/tenant/mo.**
- **CX53** (16 vCPU / 32 GB / 320 GB) = €22.49 ≈ **$27.99/mo**. 32 GB packs ~80–150 idle tenants → **$0.19–$0.35/tenant/mo.**
- **CPX line (dedicated vCPU)** ~2× cost but steadier for active tenants: CPX42 (8 vCPU/16 GB) = €25.49 ≈ $31.99 → ~40–80 tenants → **$0.40–$0.80/tenant.**
- **Hetzner per-tenant floor: ~$0.20–$0.50/mo** (cloud, shared vCPU, RAM-bound packing). **Caveat:** real microVM isolation needs *bare metal* (AX41-NVMe ~€38.40/mo, EU-only) — but the founder locked **container-per-tenant, not microVM**, so cloud CX/CPX is the right line. The isolation cost is paid in §3's risk column, not dollars.

### DigitalOcean (middle — no scale-to-zero, no microVM)

DOKS control plane is free; cluster-autoscaler **cannot scale to zero total** (min one node per pool); pod scale-to-zero needs KEDA + an always-on node floor you pay for.
- **Basic Droplet 1 GB** = $6/mo (linear ~$6/GB-RAM). **8 GB** = $48; **16 GB** = $96.
- Packing onto a 16 GB Droplet ($96), ~40–80 idle tenants → **$1.20–$2.40/tenant/mo** — notably worse than Hetzner per GB.
- Via DOKS Basic node ($12/mo, ~Basic-equivalent) + KEDA pods-to-zero: still pay the node floor; effective **~$1–$2/tenant** at moderate density.
- **DigitalOcean per-tenant floor: ~$1.00–$2.40/mo.** Per-second billing (eff. 2026-01-01) has a 60s/$0.01 floor — rapid tiny-instance churn accrues it, so prefer packing over per-tenant droplets.

### Floor summary

| Host | Per-tenant compute floor/mo | Mechanism |
|---|---|---|
| **Hetzner** | **$0.20–$0.50** | dense container bin-packing on cheap CX/CPX |
| **Fly** | **$1.30–$1.75** | native stop/suspend, $0.15/GB parked |
| **DigitalOcean** | **$1.00–$2.40** | KEDA pods-to-zero + always-on node floor |

Hetzner is ~3–8× cheaper per tenant on raw compute; Fly buys that back in operational simplicity and microVM-grade isolation (next section).

---

## 3. Three-host comparison

| Dimension | **Hetzner** | **DigitalOcean** | **Fly.io** |
|---|---|---|---|
| **Compute $/tenant/mo** | **$0.20–$0.50** (best) | $1.00–$2.40 | $1.30–$1.75 |
| **Scale-to-zero** | None native — **build-it-yourself** (logical idle via container packing) | None native — KEDA pods→0 + paid node floor; autoscaler can't zero the cluster | **Native** (auto-stop ~2s cold; suspend ~few-hundred-ms w/ caveats); stopped = $0 CPU/RAM |
| **Isolation strength** | Cloud = container wall only (no nested-virt). Real microVM ⇒ **bare metal, EU-only**. With founder's container-per-tenant lock + inner wasm jail = acceptable but the **outer wall is just the container** | Container only — **no nested-virt, no general bare metal**. Firecracker/microVM a **non-starter** | **Firecracker microVM per app** — strongest. Outer wall is microVM-grade *for free* |
| **Eng to reinvent** | High — DIY k3s/packing, hibernation, metering, backups, no managed anything | Medium — KEDA + autoscaler floor; managed PG/k8s exist | **Low** — scale-to-zero, microVM, Litestream→R2 already wired in repo `fly.toml` |
| **Object storage + egress** | Object Storage €4.99 (1 TB + 1 TB egress), overage ~€1/TB; **20 TB egress/server included (EU)** — huge | Spaces $5 (250 GB + 1 TB egress), overage $0.01/GB; pooled team bandwidth | Egress $0.02/GB (no big included pool); **Tigris** native zero-egress |
| **Managed Postgres** | **None** — self-host Patroni or external Neon/Crunchy | Yes — $15.15/mo smallest | Yes — MPG ~$38/mo smallest (pricey) |
| **Region coverage** | EU-centric (DE/FI) + US (Oregon/Virginia) + SG (penalized). **Bare metal EU-only** | Broad global | Broad global, edge-oriented |
| **Notable drift/risk** | +30–35% price hike Apr-2026 (already priced in); still ~4× cheaper than DO | Nested-virt "unsupported" stance is old but unchanged | Free tier **gone**; MPG inter-region billing starts Feb-2026; suspend dead-connection caveat |

### Take on the founder's framing

The runtime's own outer container ships **as root, no USER/seccomp/cap-drop/no-new-privileges/read-only-rootfs**. That single fact reshapes the three options:

- **"Charge more + use Fly."** Fly's Firecracker microVM *is* the outer wall — it papers over the unhardened root container at the kernel level, and it ships scale-to-zero + Litestream→R2 already wired. **You're buying isolation + ops you'd otherwise build.** Floor ~$1.30–1.75/tenant. Implies a **higher entry price** (~$18–25 range to hold a healthy multiple) but the **strongest isolation story** and fastest time-to-market. Best for the "feels like renting a flat server" promise where correctness/security matters more than squeezing margin.
- **"Charge less + use Hetzner."** 3–8× cheaper compute → you can hit a **low entry price (~$8–12)** and still clear a 3× multiple, OR hold a higher price and bank fat margin. **But:** cloud CX has no nested-virt, so the outer wall is *only the container* around a root process — you **must harden the image** (USER, seccomp, cap-drop, read-only-rootfs, per-tenant cgroups) before this is a defensible multi-tenant wall, and you build hibernation/packing/metering/backups yourself. Implies **best margin, highest engineering + isolation risk.**
- **"DO in the middle."** Genuinely middling: ~$1–2.40/tenant (worse $/GB than Hetzner), no microVM path (same container-only weakness as Hetzner cloud, *without* Hetzner's price), but **managed PG/k8s and broad regions** reduce ops vs Hetzner. It's the "fewest surprises, unremarkable margin" choice — defensible only if you value managed services and global regions over both price and isolation.

**Synthesis recommendation:** **Launch on Fly** (isolation + scale-to-zero already built; de-risks the unhardened-root-container problem), price entry in the ~$18–22 band, and **keep Hetzner as the margin-expansion target** once (a) image hardening lands and (b) you've measured real density. This is also exactly the empirical fork §7 is designed to resolve — don't commit the host before the soak test.

---

## 4. Storage + egress architecture

**Recommendation: R2 as the blob plane in front of compute, on every host.** The repo is already ~80% there — `Workbooks.Storage` is a tenant-scoped behaviour with a SigV4 adapter that serves S3 **and** R2 with config-only difference; flip `WB_STORAGE=s3`/`r2` + R2 creds, no code change. `safe_key()` already strips `..`/absolute paths so a key can't escape its tenant prefix.

**The pattern (host-agnostic):**
1. **Uploads:** app (on any host) issues a presigned PUT; browser uploads **directly to R2** — bytes never touch the compute VM (zero ingress/egress on the node).
2. **Storage:** all tenant images/files in R2, namespaced `tenant_id/blobs/key`; app DB stores only key + metadata.
3. **Serving:** R2 via a custom domain on Cloudflare's CDN (or presigned GET for private) — browsers fetch blobs straight from R2; **egress = $0, no CDN dependency required for the free egress.**
4. **Compute host only ever moves JSON/HTML (KB-scale)** — its egress meter never ticks for blobs, so the host's egress allowance is irrelevant and **you can move compute between Fly/Hetzner/DO without changing storage economics.**

**Why R2 as default:** zero egress with **no caps, no ratio limits, no CDN dependency** (official). Storage $0.015/GB-mo, Class A $4.50/M, Class B $0.36/M. Reference: serving 10 TB/mo costs ~$15 on R2 vs ~$891 on S3 egress. This matters because **published sites + generated images are served on every page view** — exactly the high-read profile that punishes egress-charging stores.

**Alternatives & when:**
- **Tigris** ($0.02/GB, also zero-egress, Fly-native, adds versioning/object-lock) — use **only if you commit to Fly** and want tightest co-location/compliance; storage ~33% pricier than R2.
- **B2** ($0.006/GB, cheapest storage) — zero-egress **only via Cloudflare Bandwidth Alliance**; use for huge cold tenant archives if already on Cloudflare.
- **Avoid Wasabi** for public image serving — "free egress" only holds while egress ≤ stored volume, plus 90-day min retention + $5.99 floor; wrong for high-churn image serving.

**Durability already solved:** per-Instance SQLite VFS is replicated off-box by **Litestream → R2** (`s3://bucket/path` prod). On Fly that survives machine replacement and restores on cold-start. **One gap to close:** `Workbooks.Storage` has **no size quota** (unlike StorageBroker's 64 MB/tenant) — add a per-tenant blob quota + total-bytes accounting above the S3 adapter before opening a hosted upload store, or storage cost is unbounded.

**Net:** blob/egress cost is **~$0.015/GB-mo storage + $0 egress** on every host — it does **not** differentiate the hosts and should be modeled as a thin pass-through addon (§5/§6), not a compute concern.

---

## 5. Managed-Postgres addon

**Recommend: offer it as a separate SKU, backed by Neon, one project per tenant.** Distinguish clearly:
- **Agent-only nexus** (default): SQLite VFS + StorageBroker KV, no Postgres. Cost floor is just §2 compute. Most tenants live here.
- **Nexus + DB** (addon): a real Postgres provisioned per tenant.

**Why Neon (not Crunchy/Supabase/self-host):** the decisive variable for a sleepy fleet is the **idle-tenant floor**, and only Neon's scale-to-zero gets it to **storage-only**:

| Backend | Idle-tenant floor | Verdict |
|---|---|---|
| **Neon** | **~$0.35–$0.70/mo** (1–2 GB asleep; compute $0 when suspended) | **Best fleet fit** — billing shape matches "many tenants, mostly idle" |
| Crunchy Bridge | $9/mo fixed (Hobby, non-prod), no scale-to-zero | N idle tenants = N×$9 — wrong shape |
| Supabase | ~$10/mo per active project + $25 org base | Only if tenant needs bundled auth/storage/realtime |
| Self-host | ~cents/tenant marginal | Cheapest cash, **highest ops + isolation burden** — later optimization only |

Neon: compute billed in CU-hours ($0.106 Launch / $0.222 Scale), storage $0.35/GB-mo, **suspended compute = $0** (auto-suspend after 5 min idle). The seam is **partly built** — `Workbooks.DB` already speaks Postgrex behind a connection URL (Neon/Crunchy/Supabase are "indistinguishable — just a URL"). **Greenfield piece:** today `WB_DATABASE_URL` is one process-global URL; a per-tenant addon needs (a) tenant→DSN registry, (b) `DB.open` resolving DSN by tenant, (c) Neon Projects API provisioning hooks.

**Pricing the SKU:** because idle tenants subsidize active ones under Neon's per-CU-hour model, a **flat addon SKU** nets positive as long as the active/idle ratio holds. Price it at `max($5–6 floor, 3× blended measured Neon cost)`. At a realistic blended ~$1–2/tenant Neon cost, a **flat ~$8–10/mo DB addon** clears a comfortable margin while idle.

**Two caveats that gate the SKU price:**
1. **Neon's $5/mo minimum is ambiguous** — official docs say none; 2026 third-party sources say $5. If it's **per-org** (one fleet org), it amortizes to ~$0/tenant (fine). If **per-project**, it's a dealbreaker for one-DB-per-tenant. **Confirm with Neon before locking the SKU.** Low-confidence until then.
2. **Project ceilings:** Scale caps at 100 projects, expandable to 1,000 on request — confirm the Neon Projects API supports automated create/suspend/delete at fleet scale.

---

## 6. Pricing model shape

Founder locks: feels like renting a flat server (a "nexus"), entry price low (~$20 *placeholder, not hardcoded*), additional nexuses cheaper than a flat re-add, upgrades = "bigger room" tiers, scale-to-zero is the internal margin engine. Express everything as **formulas tied to measured cost**, not fixed dollars.

### Tier structure (formula-driven)

Let **`C`** = measured all-in cost-per-tenant-per-month for the chosen host (§2 compute + a small storage/overhead allocation), derived empirically per §7. Let **`M`** = target gross-margin multiple (recommend **3×** as the floor multiple; SaaS infra resale healthy at 3–5×).

**Entry nexus (1 room, agent-only):**
```
price_entry = max( psychological_floor , M × C )
```
- `psychological_floor` ≈ the "$20 feels like a small server" anchor — keep it as a *named constant set by positioning*, never derived. Use ~$18–20 unless validation says otherwise.
- Example multiples below show why the floor (not the cost) binds at entry — `C` is small enough that `M × C` < floor on every host, so **the floor is the entry price and the margin is enormous.** That's the whole "scale-to-zero is the margin engine" thesis.

**Additional nexus (cheaper than flat re-add — workspace/volume model):**
```
price_addl = α × price_entry,   α ≈ 0.4–0.6
```
Justified because an additional nexus for an existing customer reuses account/identity/build-service overhead and is *just another isolated runtime + key prefix* — its marginal `C` is the same small compute floor, so a 40–60% discount still clears ≥3× on marginal cost.

**Upgrade = "bigger room" tiers (not metering):**
```
price_tier(size) = max( floor_size , M × C(size) )
```
where `C(size)` steps with the VM shape (Fly 1→2 GB, or Hetzner pack density). Sell **Small / Medium / Large rooms**, each a flat monthly — never per-request meter. e.g. shapes track Fly $5.92 (1 GB) → $11.11 (2 GB) at 3× → tier prices ~$18 / ~$33 *(illustrative; re-derive from measured C)*.

**Storage addon:**
```
price_storage = M_storage × ($0.015/GB-mo) per GB-block, M_storage ≈ 3–5×
```
i.e. ~$0.05–0.08/GB-mo retail on R2 cost, sold in blocks (e.g. "+50 GB = $3/mo"). Egress is $0 (§4) so it's pure storage pass-through.

**DB addon (§5):**
```
price_db = max( $5–6 floor , 3 × blended_Neon_cost ) ≈ flat $8–10/mo
```

### Gross margin at illustrative entry prices

Compute floor `C` from §2; entry price held at the **$20 positioning anchor** (illustrative — validate):

| Host | C (compute floor) | Entry price | Gross margin $ | Gross margin % |
|---|---|---|---|---|
| **Hetzner** | ~$0.35 | $20 | $19.65 | **~98%** |
| **Fly** | ~$1.50 | $20 | $18.50 | **~93%** |
| **DigitalOcean** | ~$1.70 | $20 | $18.30 | **~92%** |

At **$12 entry** (the "charge less + Hetzner" play):

| Host | C | Entry | Margin $ | Margin % |
|---|---|---|---|---|
| Hetzner | ~$0.35 | $12 | $11.65 | ~97% |
| Fly | ~$1.50 | $12 | $10.50 | ~88% |
| DO | ~$1.70 | $12 | $10.30 | ~86% |

**Reading:** at any sane entry price the compute floor is a rounding error — **margin is dominated by the entry anchor, not the host.** The host choice is therefore an **isolation/ops/risk decision, not a margin decision**, *until* you load in correlated-burst capacity (§8): the floor model assumes ~20% concurrent-active; if real concurrency spikes to 60–80%, Fly's per-active-second billing scales linearly (margin compresses gracefully) while Hetzner packing **hits a hard RAM wall** and you eat a server upgrade. That's the real margin risk, and it's why §7's soak test gates the decision.

---

## 7. Empirical validation plan

The numbers above are estimates with named low-confidence spots. Ordered experiments to turn them into facts:

1. **Baseline the real image.** `MIX_ENV=prod mix release` → build the runtime image → `docker history` + `docker inspect` for **compressed per-layer** sizes (registry pull is what drives cold-start/storage cost; all §1 sizes are uncompressed `du`). Confirms the ~1.3–1.5 GB and the BEAM/OS ~150–250 MB estimate. **Decision input:** real slimmed-image size.
2. **Land the two free trims, measure delta.** Add `build/commands/*.wasm`+`*.d` to `.dockerignore` (−~421 MB); confirm engine regenerates the store. Then prototype **compiler externalization** (#1 lever): pull `compilers-dist` out, stand up the shared BuildBroker service, run a Rust + a C compile end-to-end, verify the artifact lands in a tenant's CommandRegistry and runs. **Confirms −614 MB is achievable without breaking on-demand compiles.** Open question to close: does any *runtime* (not build) path resolve `compilers/` at request time? If so, the shared service needs low-latency access.
3. **Measure idle/active footprint.** Boot the slimmed release; read `:erlang.memory` / observer for **idle RSS** (confirm or kill the 80–200 MB estimate). Then drive an agent run and a compile; record peak RSS + CPU. **Confirms the packing density assumptions in §2** (tenants-per-GB).
4. **Per-host scale-to-zero / packing soak test.**
   - **Fly:** deploy N tenants with `auto_stop_machines=stop`, drive a Poisson request load, **measure real cold-start (microVM resume + page-in of the slimmed image)** — the ~1–3 s BEAM figure ignores platform resume; suspend-vs-stop trade-off; verify Litestream restore on wake.
   - **Hetzner:** bin-pack N containers on one CX/CPX, ramp concurrent-active from 10%→80%, **find the RAM wall and the tenants-per-server number.** Verify a hardened image (USER/seccomp/cap-drop/read-only-rootfs/cgroups) before treating the container as the tenant wall.
   - **DO:** KEDA pods→0 on DOKS, measure node-floor cost + pod cold-start.
5. **Wire per-tenant usage metering.** Instrument active-seconds, peak RSS, R2 storage/ops, Neon CU-hours **per tenant principal** (the broker already partitions by principal). This is what makes `C` *measured* rather than estimated, and what lets the §6 formulas self-tune.
6. **Decision rule for host selection:**
   ```
   Choose Fly  if  isolation_audit(plain container) == FAIL  AND  image_hardening not yet shipped
                   (microVM buys the wall for free; ship now)
   Choose Hetzner if image hardening SHIPPED
                   AND measured tenants/server ≥ density_target
                   AND correlated-burst soak holds margin ≥ 3×
                   (best margin once the wall + density are proven)
   Choose DO only if managed-PG + broad-region requirements outweigh
                   both price (worse $/GB than Hetzner) and isolation (no microVM)
   ```
   Default per §3: **launch Fly, migrate to Hetzner when 5(metering) + image hardening + 4(soak) clear.**

---

## 8. Open questions & risks

**Unknowns / low-confidence numbers:**
- **Idle RSS (80–200 MB)** — no measured baseline in-repo; the single biggest input to packing density and the Hetzner per-tenant floor. §7.3 resolves it.
- **Compressed image size** — all §1 sizes are uncompressed `du`; cold-start and storage cost run on compressed layers. §7.1.
- **BEAM/ERTS + debian-slim layer (~150–250 MB)** — estimate, no prod release built locally.
- **Real Fly cold-start** — the ~1–3 s BEAM boot ignores microVM resume + page-in of a 0.7–0.9 GB image; the true UX number is unmeasured (§7.4).
- **Neon $5/mo minimum** — per-org (fine) vs per-project (dealbreaker) is unconfirmed; gates the DB SKU price (§5).
- **Hetzner CPX62 top tier** (€38.99 vs €50.49 disputed); **DO autoscaler** min-node behavior sourced from synthesis not a fresh fetch.

**What could blow the margin:**
- **Correlated bursts.** The whole model rests on ~20% concurrent-active. A demo, a launch, or a cron-aligned wave can push many tenants active at once. **Fly degrades gracefully** (per-active-second billing scales linearly, margin compresses but stays positive). **Hetzner hits a hard RAM wall** — you can't pack past physical RAM, so a burst either OOMs tenants or forces an emergency server add. This is the dominant margin risk and is **host-asymmetric** — the §7.4 soak test must ramp concurrency to 80% before committing to packing.
- **Long-horizon agents defeat scale-to-zero.** Keeper/crew/autopoet runs keep a node warm indefinitely — those tenants cost full always-on, not the hibernated floor. The margin engine only works for **request-driven** tenants. Need a per-tenant "warm-hours" meter and possibly a pricing surcharge for always-on agents.
- **Cold-start UX.** If real Fly resume is 3–5 s (or the fixed-Oct-2025 30 s suspend bug recurs), first-request latency hurts the "feels like a flat server" promise. Suspend mode is faster (~hundreds of ms) but carries **dead-connection caveats** (ECONNRESET / dead DB pool on first request after resume) — needs connection-revalidation on wake.
- **Egress surprises.** Low risk *if* the R2-in-front pattern (§4) is enforced — but **any** code path that streams a blob *through* the compute host (e.g. generated images returning raw bytes with no R2 write path today) re-introduces egress on the node. Close the `image_gen.ex` "raw bytes, no persistence" gap by routing to `Storage.put` on R2. Also: `Workbooks.Storage` has **no size quota** — an unbounded uploader is an unbounded storage bill.
- **Isolation gaps (the sharpest risk).** The outer runtime container **runs as root, no USER/seccomp/cap-drop/no-new-privileges/read-only-rootfs/per-tenant cgroups.** On Fly that's masked by the Firecracker microVM. **On plain Hetzner/DO containers it is a weak multi-tenant wall** — a container-escape or kernel CVE crosses straight to sibling tenants. Tenancy `:multi` enforces JWT-org identity (anti-spoof) but that's a *logical*, not kernel, boundary. Two consequences: (1) **do not ship multi-tenant on plain containers until the image is hardened**; (2) the shared build service must guarantee `BuildBroker`'s no-net/no-fs default for the BROKER variant so one tenant's compile can't exfiltrate another's inputs. Component instances also still lack a fuel/epoch CPU cap (only wall-clock trap) — a runaway component burns a real thread until timeout; unknown how many concurrent runaways a 1-vCPU node absorbs before the BEAM is protected.

**Bottom line:** the economics are dominated by the **entry-price anchor**, not the host — every host clears >85% gross margin at a $12–20 entry. The host decision is really an **isolation + ops + burst-resilience** decision. Fly de-risks isolation and ops *today* (microVM + scale-to-zero + Litestream already wired) at ~$1.50/tenant; Hetzner offers ~$0.30/tenant **but only after** image hardening and a proven packing-density/burst soak. Land the two free trims (−~421 MB now, −614 MB via shared build service), enforce R2-in-front, offer Neon as a flat DB addon pending the $5-minimum confirmation, and let §7's measurements — not these estimates — pick the host.