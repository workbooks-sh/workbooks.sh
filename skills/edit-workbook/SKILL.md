---
name: edit-workbook
description: Edit an existing single-file HTML workbook safely. Enforces the unbundle → edit source → rebuild loop and the law that the runnable artifact is never hand-edited. Use when asked to change / fix / extend / restyle an existing workbook or `.html` mini-app.
---

# Edit a workbook

The one law: **the runnable artifact is never hand-edited.** You always recover
source, edit source, and rebuild. Bundle ⇄ unbundle is lossless and
first-class — lean on it.

## 1. Unbundle

```sh
workbook unbundle <file.html>     # or: work unpack
```

Recovers the editable source tree. **Never** open the runnable `.html` to
hand-edit it.

## 2. Locate the edit

Map the requested change to the right source surface: markup, style, script,
data, or a WASM recipe.

## 3. Edit source only

Apply the **smallest** change that satisfies the request. If the change adds a
dependency, route it through the WASM lane — see `references/wasm-deps.md`
(create-workbook step 3): classify, convert, file an issue if it can't convert.
No native execution.

## 4. Rebuild

```sh
workbook build
```

## 5. Verify at the tightest tier

```sh
workbook dev
workbook check
```

Re-read the changed source. Confirm **no raw input leaked into the runnable**
and the bundle round-trips losslessly.

## 6. Ship

```sh
workbook publish        # or: work publish apply  → prints a URL
work sign / work verify     # if signing
```

**Live-confirm:** fetch the served artifact and check it. Don't trust the commit
— trust the bytes the URL serves.

## References

- `references/cli.md` — `workbook` vs `work` (shared with create-workbook).
- `references/wasm-deps.md` — dependency-conversion table (shared with create-workbook).
