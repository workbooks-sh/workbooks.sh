# Connect your own Google Cloud (bring-your-own auth)

This toolkit runs the **`gws`** CLI ([googleworkspace/cli](https://github.com/googleworkspace/cli))
against **your own Google Cloud project**. There is no shared client id — you authorize once on
your side and bring the credential. The nexus only holds the sealed result and injects it into the
sandboxed `gws` at run time.

## The fastest path (with gcloud)

```bash
gws auth setup     # one-time: creates the Cloud project, enables APIs, logs you in
gws auth login     # pick scopes, log in
gws auth export --unmasked > credentials.json   # export the credential to bring here
```

Paste the contents of `credentials.json` into the dashboard (Toolkits → Google Workspace →
Connect → **Credentials JSON**), or paste a short-lived token under **Access token**:

```bash
gcloud auth print-access-token        # → paste as the Access token credential
```

## Manual setup (no gcloud)

1. In the Google Cloud Console, create an **OAuth client** of type **Desktop app** in your project.
2. Download the client JSON.
3. Add yourself as a test user on the OAuth consent screen.
4. Run `gws auth login`, then `gws auth export --unmasked` and bring the credential here.

## What the nexus does with it

- The credential is sealed (AES-256-GCM) as a per-connection secret — never stored in plaintext.
- At run time it is injected into the sandboxed `gws` as `GOOGLE_WORKSPACE_CLI_TOKEN` (token) or
  `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` (a path to the written JSON inside `/work`).
- Which command groups agents may run is gated by the connection's permission checklist on the
  details page (e.g. you can allow `drive`/`gmail` but block `admin`).
