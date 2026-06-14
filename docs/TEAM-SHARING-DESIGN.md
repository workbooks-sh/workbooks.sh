# Team / Sharing — design + seat pricing

*Date: 2026-06-14. How a workspace shares nexuses with teammates, priced, with WorkOS owning the entire invite/member/role lifecycle so it "manages itself." Companion to `docs/AUTH-LAYERING-RESEARCH.md` (two-plane auth) and `docs/HOSTED-NEXUS-ECONOMICS.md` (pricing). Lands in the web dashboard first, the desktop browser after.*

---

## The model: workspace = WorkOS Organization

- **Workspace = WorkOS Organization** — the team **and** billing boundary. It owns nexuses; it has members. The platform tenant (`org_id`) is already our tenant key, so a workspace maps 1:1 to the ownership scope the nexus registry uses.
- **Members = WorkOS Organization Memberships** with **Roles** (WorkOS RBAC): **Owner/Admin** (manage members, billing, nexuses), **Member** (use the workspace's nexuses), optional **Viewer**.
- **Invites = WorkOS Invitations** — admin invites an email, WorkOS sends the email, the invitee accepts → membership. We send no email and store no member records of our own.

## It manages itself: the WorkOS User Management widget

The entire team surface in the dashboard is the embedded **WorkOS User Management widget** — paginated members table (avatar, name, email, role, last-active, status), server-side search + role filter, per-user **edit-role / remove**, and the **admin invite flow**. We do not build any of that UI.

- **Token:** the dashboard backend mints a short-lived widget token for the signed-in admin:
  ```ts
  const authToken = await workos.widgets.getToken({
    userId, organizationId, scopes: ['widgets:users-table:manage'],
  }); // 1-hour expiry; acting user needs a role with that permission (Admin by default)
  ```
- **Embed:** pass `authToken` to the widget surface in the dashboard's Team route. SvelteKit integration per the `workos-widgets` SvelteKit reference.

So invite / accept / list / role-change / remove are **100% WorkOS** — no custom member CRUD, no email infra, no role engine to maintain.

## Self-managing billing: WorkOS webhooks → Polar seat quantity

Seats stay in sync with zero manual steps:
1. Admin invites a teammate in the widget → WorkOS sends the invite → teammate accepts.
2. WorkOS webhook `organization_membership.created` → PCP → **bump the workspace's Polar subscription seat quantity (+1)**.
3. Removal → `organization_membership.deleted` → seat quantity (−1).

The bill self-adjusts as the team grows/shrinks. The PCP's only team code is: mint widget tokens + handle the two membership webhooks → Polar. Everything else is WorkOS + Polar.

---

## Seat pricing

**Cost reality:** a teammate costs us ~**$0** on WorkOS (User Management / orgs / memberships / invitations are free to 1M MAU) and ~$0 on compute (members *share* the workspace's existing nexuses; their agent runs already meter as usage). The **only** team feature that costs real money is **SSO/SCIM** — WorkOS charges ~**$125/SSO connection/mo** (+ SCIM). So: don't tax collaboration; monetize governance + the usage teams drive, and recover the real WorkOS cost at the enterprise tier.

Three structures (numbers are placeholders — validate empirically like the rest of pricing):

**A — Free seats, usage-funded (most on-brand).** Members are free, unlimited. Revenue scales through the nexuses + compute/storage/DB the team consumes (already metered). SSO/SCIM = paid Enterprise add-on. *Pro:* zero collaboration friction, strong "no per-seat tax" differentiation, matches the usage-based ethos. *Con:* a big team on one small nexus underpays; revenue doesn't track headcount directly.

**B — Light per-seat (classic).** Workspace includes owner + ~2 free collaborators; additional seats ~$10/member/mo (near-pure margin). SSO/SCIM on top. *Pro:* predictable expansion revenue. *Con:* per-seat friction — the thing developers dislike.

**C — Hybrid tiers (recommended).**
- **Starter (solo):** 1 owner; pay per nexus + usage. Collaborators capped low (e.g. +1).
- **Team:** a flat per-workspace plan that **includes a generous seat band** (e.g. up to ~10) + roles + audit + shared billing — *flat, not per-seat*, so teams aren't nickel-and-dimed; only beyond the band a light per-seat kicks in.
- **Enterprise:** SSO + SCIM/Directory Sync + SAML + advanced roles + SLA — priced to cover WorkOS's per-connection cost and the governance value.

**Recommendation: C.** It keeps collaboration cheap/flat (you don't punish teams for adding people), it monetizes the real cost lever (SSO/SCIM) where it actually exists (enterprise), and the membership-webhook → Polar sync makes whatever band/overage we choose self-managing. The flat team band is the developer-friendly middle between "free-for-all" (A leaves money on the table for large collaborative teams) and "per-seat tax" (B's friction).

**Billing entity:** the workspace (WorkOS org). Its Polar subscription has line items: nexus plan(s) + seat band/overage + metered usage. Owner/Admin role manages billing; the role is assigned in the same WorkOS widget.

**Entitlements:** seat-band overage auto-bills via the webhook (soft cap + "you've added a seat, +$X/mo" notice — no hard block, less friction). SSO/SCIM is gated by plan (the Admin-Portal SSO widget only appears on Enterprise).

---

## Dashboard surface (web first)

- A **Team** view in the dashboard: the embedded WorkOS **User Management widget** + a **seat-usage strip** (members vs included band, with an Upgrade prompt when over).
- Enterprise workspaces additionally get the **Admin Portal SSO Connection** + **Domain Verification** widgets (also WorkOS-hosted) for self-serve SSO setup.
- Desktop "browser" gets the same Team view later by pointing at the same PCP token endpoint + embedding the same widget.

## What we build vs what WorkOS/Polar own
| Piece | Owner |
|---|---|
| Invite email, accept flow, members table, role edit, remove | **WorkOS** (User Management widget) |
| Roles / permissions (Owner/Admin/Member) | **WorkOS** RBAC |
| SSO / SCIM self-serve setup | **WorkOS** Admin Portal widgets |
| Seat → bill sync, plan/entitlements, checkout | **Polar** (driven by 2 webhooks) |
| Mint widget token; handle 2 membership webhooks; gate widgets by plan | **us** (PCP — small) |
| Team view shell + seat-usage strip in the dashboard | **us** (frontend) |

## To go live (handoff)
The team flow is live the moment we have **WorkOS API key + Client ID** and a confirmed **roles config** (Admin role carrying `widgets:users-table:manage` — default on new WorkOS accounts). Then: scaffold the dashboard's Team route (SvelteKit) + the `getToken` endpoint + embed the widget. Independent of the nexus API (Phase 3), so it can ship as a standalone vertical slice ahead of the rest of the dashboard.
