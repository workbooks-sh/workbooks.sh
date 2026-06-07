// Clerk-based auth locals, populated by hooks.server.ts via @clerk/backend.
declare global {
  namespace App {
    interface Locals {
      auth: {
        userId: string | null;
        sessionId: string | null;
        user: {
          id: string;
          email: string | null;
          firstName?: string | null;
          lastName?: string | null;
          imageUrl?: string | null;
        } | null;
        // Short-lived JWT for API calls; null if not signed in.
        sessionToken?: string | null;
      };
    }
  }
}

export {};
