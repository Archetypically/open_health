# Xcode Cloud → auto TestFlight on merge

A clean Xcode Cloud checkout has **none** of the gitignored build inputs
(`OuraCore.xcframework`, `OuraApp.xcodeproj`, libtorch, the `.ptl` models, `oura.db`).
So CI rebuilds what it can and generates the Xcode project from a spec:
`ci_scripts/ci_post_clone.sh` builds the Rust xcframework, then runs
`xcodegen generate` in `apps/ios/OuraApp/`.

| build | `OURA_CI_TORCH` | spec | ships |
|---|---|---|---|
| model-free (default) | unset | `project-ci.yml` | repo + Rust core; syncs a real ring over BLE |
| with the on-device models | `1` | `project-torch-ci.yml` | + libtorch runtime + the `.ptl` models |

## One-time setup

**1. An app record.** App Store Connect → **Apps** → **+** → **New App**, with the
bundle id `md.thomas.openoura`. Creating it needs the App Manager, Admin or Account
Holder role (or the *Create Apps* permission).

**2. Authorize the repository.** App Store Connect → your app → **Xcode Cloud** tab,
add the GitHub source, then approve the *Xcode Cloud* GitHub App on
`Archetypically/open_health` — your own fork. That approval is the whole reason for
the fork: GitHub requires admin on the account that owns the repo, and upstream
`Th0rgal/open_health` is a personal account you do not control.

**3. Create the first workflow in Xcode, not in App Store Connect.** Apple requires
the initial setup in Xcode, and it needs a project window — so generate one first,
the same way a CI run will:

```bash
cd apps/ios/OuraApp && xcodegen generate --spec project-ci.yml && open OuraApp.xcodeproj
```

Then **Product → Xcode Cloud → Create Workflow…** and fill in:

| section | setting |
|---|---|
| General | name it; tick **Restrict editing** (required for review-eligible builds) |
| Environment | macOS + Xcode versions; add the env vars from the torch section below, ticking **Keep value redacted** for the token |
| Start Conditions | **Branch Changes** on `customizations` (leave *Auto-cancel Builds* on) |
| Actions | **Archive** → scheme `OuraApp`, platform iOS → *TestFlight (Internal Testing Only)* |
| Post-actions | **TestFlight** → Internal, and add yourself as a tester |

`ci_scripts/ci_post_clone.sh` runs automatically before the actions; it is committed
mode `755`, which Xcode Cloud requires. After the first successful build you can edit
and create workflows in **App Store Connect → your app → Xcode Cloud** instead.

That is it — each push to `customizations` produces a TestFlight build.

## Repository layout

`Archetypically/open_health` is a public fork of `Th0rgal/open_health` inside its
fork network, so GitHub keeps `main` in sync with upstream on its own — that is also
what makes the **Sync fork** button work. Your work is not on `main`:

| branch | contents |
|---|---|
| `main` | upstream's history only; auto-synced, never committed to by hand |
| `customizations` | your commits, currently one ahead of `main` |

That is why the start condition above is a push to `customizations`. When upstream
moves, bring it forward from that branch:

```bash
git fetch upstream
git rebase upstream/main                    # on customizations
git push --force-with-lease origin customizations
```

Rebasing keeps your commits linear instead of accumulating merge commits. The
trade-off: an auto-synced `main` never goes through CI, so upstream commits land
unbuilt — only your pushes to `customizations` are verified by a build.

## Build numbers

Never hardcode `CURRENT_PROJECT_VERSION` in a CI spec: TestFlight rejects a build
number it has already seen, so a literal means the second run fails to upload.
`ci_post_clone.sh` stamps `CI_BUILD_NUMBER` from the UTC clock and exports it;
xcodegen expands `${CI_BUILD_NUMBER}` in the spec. The commit count is not a usable
source — Xcode Cloud clones shallow, so `rev-list --count` returns 1. The local
`project.yml` keeps its literal because that path is a manual upload, not CI.

## The model-free build (default)

Nothing to configure. CI compiles the Rust core, links both the `ios-arm64` and
`ios-arm64-simulator` slices of `OuraCore.xcframework`, and archives. The on-device
hypnogram / CVA / activity / illness models are compiled out (`#if TORCH`).

## The torch build (opt-in)

Set these in the workflow's environment:

| variable | value |
|---|---|
| `OURA_CI_TORCH` | `1` |
| `LIBTORCH_XCFRAMEWORKS_URL` | release-asset URL of `libtorch-xcframeworks.tar.gz` |
| `MODELS_BASE_URL` | private prefix holding the five `.ptl` files |
| `MODELS_TOKEN` | bearer token for that store |

The script fails fast naming the missing variable, rather than generating a project
that cannot compile.

`project-torch-ci.yml` is `project.yml` **minus the `oura.db` resource**: a cloud
checkout has no personal database (the app builds its own from the ring over BLE),
and xcodegen errors on a missing source path. Its header search paths point at the
vendored `include/` tree instead of the local libtorch build dir, since an
xcframework carries binaries and dSYMs but no headers.

### 1. Build libtorch once, publish it — never in CI

The CMake build takes hours, so it happens locally, once:

```bash
cd apps/ios
./spike/build_libtorch_ios.sh          # simulator → local/libtorch-ios/pytorch/build_ios
./spike/build_libtorch_ios.sh device   # device    → …/build_ios_device
./package-libtorch-xcframeworks.sh     # → apps/ios/libtorch-xcframeworks/ (+ include/, + the tar command)
```

Attach the resulting `libtorch-xcframeworks.tar.gz` to a release on this repo and
put its URL in `LIBTORCH_XCFRAMEWORKS_URL`. PyTorch is BSD, so a public asset leaks
nothing — this repo is public, and a release asset on it is world-readable.

### 2. Host the `.ptl` models privately

The models are decrypted Oura weights, so they must never enter git — not a
commit, not Git LFS, and not a release asset on a public repo. Put all five under
one private prefix (`sleepnet_moonstone_1_2_0.ptl`, `cva_2_1_0.ptl`,
`automatic_activity_detection_3_1_11.ptl`, `steps_motion_decoder_2_0_0.ptl`,
`illness_detection_0_5_1.ptl`) and give CI a bearer token. The specs hardcode those
names under `notes/models/mobile/`, so CI must write them there verbatim.

### 3. Why a release asset and not LFS

LFS would work, but it adds a git-lfs dependency, spends the repository's LFS
bandwidth on every CI run, and leaves the binaries in history forever. A tarball
fetched by `ci_post_clone.sh` is one HTTP request from a CDN-backed asset and
nothing to install.

## Verified locally

Both CI paths were exercised on a workstation, not just reasoned about:

- `build-xcframework.sh` produces `OuraCore.xcframework` with an `ios-arm64` slice
  whose objects carry `LC_VERSION_MIN_IPHONEOS`, and an `ios-arm64-simulator` slice
  with `LC_BUILD_VERSION platform 7` — real iOS binaries, not a macOS fallback.
- `ci_post_clone.sh` (model-free) runs clean: Rust core, bindings, xcframework,
  then `xcodegen generate`.
- The generated model-free project builds for device in Release against the
  `ios-arm64` slice.
- `project-torch-ci.yml` generates with placeholder artifacts, wiring all four
  libtorch xcframeworks, the vendored `include/` path, and no `oura.db`.

The torch *compile* is the one thing not verified here: it needs the real libtorch
build and the real `.ptl` files, neither of which is on this machine.

## Local developer directory

If `xcode-select` points at Command Line Tools, `xcrun` cannot find the iPhoneOS
SDK and the iOS link fails with a confusing macOS-sysroot error.
`build-xcframework.sh` detects this and exports `DEVELOPER_DIR` to the installed
Xcode for the length of the script; run `sudo xcode-select -s
/Applications/Xcode.app/Contents/Developer` once to fix the shell for good.
