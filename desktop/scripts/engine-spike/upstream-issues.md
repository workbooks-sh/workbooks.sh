# libkrun upstream issue drafts (wb-ryw findings, 2026-06-10)

Drafts only — review before posting. Target repo: github.com/libkrun/libkrun.
All repros on macOS 15 (Apple Silicon), krunvm 0.2.6, libkrunfw 5.5.0.

---

## 1. NEW ISSUE — v1.19.0 regression: TSI guest listens no longer bind host ports

**Title:** v1.19.0 regression: guest `listen()` under TSI never produces a host-side bind (works on v1.18.1)

**Body:**

On libkrun v1.18.1, a guest process listening on a mapped port produces a
host-side listener owned by the krunvm process (TSI impersonation working as
documented). After upgrading to v1.19.0 (same krunvm 0.2.6, same libkrunfw
5.5.0, same VM definition), the identical guest workload binds successfully
in-guest but the host process holds **zero** TCP sockets — `lsof -nP -i :4000`
shows nothing, and host connections are refused.

Bisect: downgrading only libkrun 1.19.0 → 1.18.1 (brew bottle) restores the
host bind immediately. Nothing else changed.

Repro: krunvm VM with `--port 4000:4000`; guest runs any TCP listener on
0.0.0.0:4000 (we used an Erlang/OTP `gen_tcp.listen`); check
`lsof -nP -i :4000` on the host.

The v1.19.0 release notes are nearly empty, so we could not identify the
intended change. Happy to test patches.

---

## 2. COMMENT on #344 / #511 — TSI serializes all socket ops behind a parked blocking accept

**Body:**

Real-workload data point for the TSI unresponsiveness/concurrency reports.

We bisected a BEAM (Erlang VM) web server that "hung at startup" inside
krunvm down to this mechanism: while one guest thread is parked in a blocking
`accept()` on a TSI socket, **every other socket control operation on the
guest queues behind it** — `getsockname`, `getpeername`, `setsockopt`, even
reads on already-established connections. The queued ops flush only when the
NEXT inbound connection completes the parked accept.

Two observable consequences:
1. Server frameworks that query the listener right after binding (our case:
   Bandit/ThousandIsland calling `sockname` for a startup log line) deadlock
   forever on an idle listener — boot hangs with no traffic to flush the queue.
2. Under traffic, request handling runs "one connection behind": the ops for
   connection N flush when connection N+1 arrives. From the client this looks
   like empty replies / connection drops on every request.

Workaround that fully resolves it for us: replace the parked blocking accept
with a short-timeout polling accept (`accept(..., 250ms)` in a loop). With
that single change the same server answers instantly.

Versions: libkrun 1.18.1 and 1.19.0 (both affected), libkrunfw 5.5.0,
krunvm 0.2.6, macOS 15 arm64. Can share a minimal Erlang repro script.

---

## 3. COMMENT on #414 (or new issue) — virtio-fs root cannot carry a many-small-file app boot

**Body:**

Quantified data point for virtio-fs root performance on macOS.

Workload: a BEAM/Erlang release (~10k files: bytecode modules, NIF .so's,
sqlite db, a 30MB model file) booting from a krunvm virtio-fs root.

- krunvm (virtio-fs root): cold boot to first HTTP response took **8 minutes
  to never** (boots regularly stalled minutes between supervision-tree steps;
  guest timers and console output starve during the I/O storm).
- Identical OCI image with a block-device root (Docker VM, and separately
  vfkit + raw ext4 conversion): **0–5 seconds** to the same HTTP response.

The per-read round-trip cost times thousands of small reads appears to be the
dominant term; no individual operation fails.

Ask: either virtio-blk root support in krunvm (the krunkit direction), or an
explicit pointer in krunvm docs that many-small-file workloads should use a
disk-image root via krunkit/EFI.

---

## 4. (Conditional) COMMENT on #579 — BufDescTooSmall / large POST drops

Only post if we observe large-payload drops once real workloads run through a
TSI path again. Keep the repro handy: POST > 64KB through a TSI-mapped port,
watch for silent truncation/drop.

---

Posting plan: 1 first (regression, time-sensitive — others will hit it as
brew bottles roll), then 2 and 3 same day. All reference each other.
