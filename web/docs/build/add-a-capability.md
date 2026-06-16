
# Grant a capability to a toolkit

> Declare the caps a toolkit imports, match them to its WIT world, and pick the right isolation profile so the grant is real.

The goal: let a toolkit reach the host for exactly one thing (a socket, the LLM,
durable storage) — and nothing more. A capability is never ambient. You **declare**
it in three places that must agree, and the host fails closed if they don't.

The three places:

1. The toolkit manifest's `#+CAPS:` line — the author's request.
2. The component's WIT world / Dock `bind!` list — what the code actually imports.
3. The isolation **profile** the caller runs under — the ceiling on what any grant
   can authorize.

## Steps

1. **Declare the cap in the manifest.** Add it to the `#+CAPS:` front-matter of the
   toolkit's `manifest.org`. This is the authoring contract for the grant.
- **MATURITY:** ships-today
- **EVIDENCE:** toolkits/icons/manifest.org:14
- **SRC:** toolkits/icons/manifest.org#CAPS

2. **Import it in the Dock SDK.** The cap list in `dock::bind!` (Rust) or `bind(imports)`
   (JS) **is** the cap-scoping — it must match the WIT world and the `#+CAPS` grant.
   See [The Dock SDK](dock-sdk.md).
- **MATURITY:** ships-today
- **EVIDENCE:** web/docs/build/dock-sdk.md:13

3. **Pick an isolation profile that permits the cap.** A grant only takes effect if
   the running profile's ceiling allows it. The profiles and their cap sets are
   defined in the policy:
- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/policy.ex:29
- **SRC:** runtime/host/policy.ex#profiles

   - `compute` — `vfs` only. Pure compute + ephemeral vfs. No exec, kv, secrets, net.
   - `minimal` — every LOCAL cap (`vfs commands exec kv secrets queue`) plus the
     SSRF-brokered raw sockets (`tcp udp tls`), but **no** high-level egress.
   - `network` — `minimal` plus `net llm browse` (host HTTP egress + LLM).
   - `posix` — `network` plus `posix parallel` (the full surface).

   A high-level egress cap (`net`, `llm`, `browse`) requires the `network` profile or
   above; `minimal` grants raw sockets but the wasi:http / DNS gate stays closed.
- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/policy.ex:66
- **CAVEAT:** minimal still authorizes signing + raw-socket egress — choose compute for a true sandbox.

## Fail-closed by design

An unknown or misspelled profile does not default to `minimal` — it falls back to
`compute` (`vfs` only), the **least** privilege. A typo can never silently authorize
secrets, exec, or raw sockets.

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/policy.ex:69

- The capabilities themselves: [The Dock & capabilities](../concepts/the-dock.md)
- Isolation profiles in depth: [Isolation tiers & trust](../run/tiers.md)
- Full cap reference: [Dock capabilities](../reference/caps.md)
