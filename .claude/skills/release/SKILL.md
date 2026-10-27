---
name: release
description: Cut a new NovaClipboard release — pick the next version (semver from Conventional Commits unless the user names one), write bilingual en/vi release notes in the established format, create and push the annotated tag, publish the GitHub release, and watch the Release workflow. Use when the user asks to release, tag, or ship a new version (e.g. "release bản mới", "tạo tag v0.6.0").
---

# Release NovaClipboard

Pushing a `v*.*.*` tag triggers `.github/workflows/release.yml`, which builds, signs, notarizes, uploads the DMG + `appcast.xml` to R2 (Sparkle auto-update reaches every user) and attaches the DMG to the GitHub release. A pushed tag is effectively a production release, so **never push the tag before the user approves the version and notes** (step 4).

Arguments: an optional version (`v0.6.0`, `0.6.0`) and optional extra notes, such as known issues to call out.

## 1. Sync and check

```
git fetch --tags origin
git switch master && git pull --ff-only
git status --short          # must be clean
```

Stop and tell the user if the tree is dirty, `master` can't fast-forward, or `HEAD` already has a tag (`git tag --points-at HEAD`).

Find the previous release tag: `git describe --tags --abbrev=0 --match 'v*.*.*'`. If there are no commits since that tag, there is nothing to release; say so.

## 2. Pick the version

If the user gave a version, use it (normalize to `vX.Y.Z`). It must be greater than the previous tag and must not exist yet.

Otherwise bump from the previous tag using **Semantic Versioning + Conventional Commits**. Read every commit since the previous tag, *including the commits inside merged PRs*: `git log <prev>..HEAD --no-merges --format='%s%n%b'`.

| Commits since the previous tag | Bump |
|---|---|
| Any breaking change (`type!:` or a `BREAKING CHANGE:` footer) | major; **while major is 0, minor instead** (the usual 0.x convention, as in release-please's `bump-minor-pre-major`) |
| Any `feat:` | minor |
| Only `fix:`, `perf:`, `refactor:`, `revert:` | patch |
| Only `ci:`, `docs:`, `chore:`, `test:`, `build:`, `style:` | no user-facing change: ask whether to release at all; if yes, patch |

Take the highest bump that applies. Tell the user which commits decided it.

## 3. Write the notes

Gather the content from the merged PRs (`gh pr list --state merged --search "merged:>=<prev tag date>"`, `gh pr view <n>`) and the commits. Write for **end users**: describe what they can now do or what stopped breaking. No type names, file names, APIs or CI details. CI-only changes don't go into the notes.

Use exactly this structure (it matches v0.5.0 and v0.5.1). Leave out any section that would be empty, in both languages:

```
## What's new

- **<Feature>** — <one or two sentences>.

## Changed

- ...

## Fixed

- ...

## Known issues

- ...

---

## Có gì mới

- **<Tính năng>** — <mô tả>.

## Thay đổi

- ...

## Sửa lỗi

- ...

## Lưu ý

- ...

---

**Full Changelog**: https://github.com/novapizza/NovaClipboard/compare/<prev>...<new>
```

- The Vietnamese half mirrors the English one item for item, written naturally with full diacritics (not word-for-word). Keep shortcuts and product names as they are (⇧, Return, Quick Look, Google Docs).
- Put limitations the user mentions, and ones known from the PRs, under **Known issues / Lưu ý**.
- Also draft the tag annotation as one line: `vX.Y.Z: <comma-separated highlights> (PR #a, #b)`.

Write the notes to a file in the scratchpad directory.

## 4. Get approval

Show the user the version (and why), the tag message and the full notes. Say that pushing the tag publishes the update to all users through Sparkle. **Wait for an explicit go-ahead.** Apply any edits they ask for and show the result again.

## 5. Tag and publish

```
git tag -a vX.Y.Z <HEAD sha> -m "<tag message>"
git push origin vX.Y.Z
gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file <notes file>
```

Create the release right after pushing the tag. The workflow's "Create GitHub Release" step runs much later, finds the release, and only uploads the DMG to it. If it ran first, it would create a release with generated notes; in that case replace them with `gh release edit vX.Y.Z --title "vX.Y.Z" --notes-file <notes file>`.

## 6. Watch the workflow

Find the run with `gh run list --workflow release.yml --limit 1`. Watch it in the background with `gh run watch <id> --exit-status`; it takes several minutes. When it finishes:

- **Success:** confirm `NovaClipboard-X.Y.Z.dmg` is attached (`gh release view vX.Y.Z --json assets`), then give the user the release link.
- **Failure:** report the failing step and the relevant log lines (`gh run view <id> --log-failed`). Don't delete or move the tag, and don't re-run without asking: notarization or R2 may already have happened.
