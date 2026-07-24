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

A fresh public clone therefore supports building the source and running fixture-independent tests, but the full RAW/JPEG/calibration suite requires the private local fixture set. Separating those two test tiers into explicit commands is a repository-hardening task; missing private media must not be replaced by arbitrary public photographs because that would invalidate the recorded hashes and quality contract.

## Branch and version policy

- `main`: the latest runnable, reviewed baseline
- `feature/<topic>`: work intended to become part of the product
- `experiment/<hypothesis>`: bounded alternatives such as Metal presentation or color-pipeline trials
- annotated tags: important reproducible baselines

Experiments should declare their acceptance threshold before measurement. An unsuccessful experiment is documented and closed rather than kept as a permanent alternate product branch. Long-lived product variants should be created only when their user contract truly differs, not merely to preserve old code; Git tags already provide that history.
