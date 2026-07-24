# Repository and local data policy

Photo Bench is developed in a public source repository, but the owner’s photo library and Lightroom comparison assets remain private and local.

## Tracked in Git

- Swift and Python source code
- tests and build scripts
- design, calibration, benchmark, and review documents
- calibration manifest definitions
- owner-authored XMP presets used by the parser and calibration contracts

## Never tracked in Git

- original JPEG, TIFF, HEIC, or RAW photos
- Lightroom reference exports and teacher images
- `.photobench/` renders, reports, benchmark runs, and local traces
- `dist/`, `exports/`, `.build/`, signed app bundles, and caches
- credentials, environment overrides, security-scoped bookmarks, or Lightroom catalog data

These files are excluded by [`.gitignore`](./.gitignore). Git and Git LFS are not a backup destination for the private photo library. Originals, Lightroom migration assets, and formal teacher outputs need a separate local backup with a hash-and-count manifest before the Adobe subscription is cancelled.

## Local calibration data

The checked-in `calibration/manifest-v*.json` files define the expected filenames, hashes, comparison matrix, and gates. The referenced media stays at the repository root only on an authorized development Mac. Formal reports are regenerated into `.photobench/` and their accepted summary is recorded in the Markdown evidence documents.

A fresh public clone therefore supports building the source, but the top-level `swift test` still mixes fixture-independent coverage with owner-only RAW/JPEG integration tests. A clean-clone audit of commit `3a0169d` / tag `prototype-p1-2026-07-24` on 2026-07-24 built successfully and then reported 25 fixture-missing issues out of its 93 tests. A separate no-local clean clone of the current experiment branch tracked no private media, built successfully, and ran all 130 tests; it reported the same 25 issues, all caused by the absent owner-only JPEG / RAW fixtures. The branch adds 37 fixture-independent Metal lifecycle/arbiter/probe/renderer tests, and those tests pass without private media. Separating the two tiers into explicit commands is still a repository-hardening task and a prerequisite for public CI; missing private media must not be replaced by arbitrary public photographs because that would invalidate the recorded hashes and quality contract.

The ignore rules reject common camera RAW and raster-photo formats, XMP sidecars, live SQLite databases and sidecars, Lightroom Classic catalogs / helper data / preview packages / catalog backups, and Lightroom cloud libraries at any directory depth and with mixed-case extensions. A redistributable synthetic fixture must receive an explicit allowlist rule before it is staged.

The public calibration manifests intentionally expose fixture filenames and SHA-256 values, camera/exposure metadata, and the recorded test hardware/runtime identity, but never the media bytes. Treat changes to that metadata as public disclosure and review them before every push.

## Branch and version policy

- `main`: the latest runnable, reviewed baseline
- `feature/<topic>`: work intended to become part of the product
- `experiment/<hypothesis>`: bounded alternatives such as Metal presentation or color-pipeline trials
- annotated tags: important reproducible baselines

Experiments should declare their acceptance threshold before measurement. An unsuccessful experiment is documented and closed rather than kept as a permanent alternate product branch. Long-lived product variants should be created only when their user contract truly differs, not merely to preserve old code; Git tags already provide that history.

## License status

The repository is public but currently has no `LICENSE`. Until the owner chooses terms, public visibility does not grant a general right to reuse, modify, or redistribute the project. License selection must also account for third-party metadata embedded in the reviewed XMP fixtures.
