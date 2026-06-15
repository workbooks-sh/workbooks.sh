/**
 * Bridge: organization membership + share-to-organization.
 *
 * Talks to the single Host capability surface (the Tauri `invoke` seam).
 * In the browser preview these resolve against the webHost mock providers
 * (real org members with photo avatars, stateful per-resource shares); a
 * real web build routes the same `org_*` verbs to the runtime.
 *
 * Shape mirrors the mock seed in $lib/platform/webHost.ts.
 */

import { invoke } from "@tauri-apps/api/core";

export interface OrgMember {
  handle: string;
  display_name: string;
  /** Real photo URL (or data URL). */
  avatar: string;
  email: string;
  title: string;
}

export interface OrgInfo {
  id: string;
  name: string;
  /** Assignable roles the share modal offers. */
  roles: string[];
}

export interface ShareRecipient {
  handle: string;
  role: string;
  shared_at: number;
}

export async function getOrg(): Promise<OrgInfo> {
  return invoke<OrgInfo>("org_current");
}

export async function listMembers(): Promise<OrgMember[]> {
  return invoke<OrgMember[]>("org_members");
}

export async function sharesFor(resourceId: string): Promise<ShareRecipient[]> {
  return invoke<ShareRecipient[]>("org_shares_for", { resource_id: resourceId });
}

/** Upsert recipients for a resource; returns the full recipient list. */
export async function share(
  resourceId: string,
  recipients: { handle: string; role: string }[],
): Promise<ShareRecipient[]> {
  return invoke<ShareRecipient[]>("org_share", {
    resource_id: resourceId,
    recipients,
  });
}

export async function unshare(
  resourceId: string,
  handle: string,
): Promise<ShareRecipient[]> {
  return invoke<ShareRecipient[]>("org_unshare", {
    resource_id: resourceId,
    handle,
  });
}
