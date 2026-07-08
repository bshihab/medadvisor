# Model delivery via Apple-hosted Background Assets (iOS 26) — PARKED

> **STATUS: parked, not shipping.** The iOS 26 daemon proved unreliable in
> practice (downloads park on lock, force-quit destroys progress, corrupted pack
> states, TestFlight-only testing). The app now downloads the model directly
> (Cloudflare R2 + HuggingFace mirror, byte-range resume) — see README "Model
> delivery" v3. This playbook is kept for a future revisit once the OS matures.
> The `qwen7b-q4` pack should stay **archived** in App Store Connect meanwhile,
> so installs don't ghost-prefetch 4.3 GB the app no longer reads.

The Qwen2.5-7B GGUF (~4.3 GB) ships as an **Apple-hosted managed asset pack**
instead of a HuggingFace download. Apple hosts it on their CDN (fast, free), and
the OS downloads it — so it survives force-quit, backgrounding, and reboots.

- Asset pack ID: **`qwen7b-q4`**
- Download policy: **on-demand** (see `ModelAssets/Manifest.json`)
- App Group (app + downloader extension share it): **`group.app.medadvisor`**

The `.gguf` itself is **not committed** (4.3 GB). Drop it at
`ModelAssets/Qwen2.5-7B-Instruct-Q4_K_M.gguf` before packaging.

---

## One-time setup (Apple Developer portal)

1. **Register the App Group** `group.app.medadvisor`
   (Certificates, Identifiers & Profiles → Identifiers → App Groups → +).
2. Add that App Group to **both** App IDs:
   `app.medadvisor.MedAdvisor` and
   `app.medadvisor.MedAdvisor.ModelAssetsDownloader`.
   (XcodeGen writes the entitlement; the portal must know about it too.)

---

## Build the asset pack (on the Mac with the gguf present)

```bash
cd ~/bilal-dev/medadvisor

# 1. Put the model here (gitignored):
#    ModelAssets/Qwen2.5-7B-Instruct-Q4_K_M.gguf

# 2. Package it into a .aar archive (paths in the manifest are repo-root-relative)
mkdir -p build
xcrun ba-package package ModelAssets/Manifest.json \
  --output-path build/qwen7b-q4.aar
```

`xcrun ba-package template` regenerates a blank manifest if you ever need one.

---

## Upload to App Store Connect

**Easiest — Transporter app:** drag `build/qwen7b-q4.aar` into Transporter,
assign it to the MedAdvisor app, click **Deliver**. Then in App Store Connect the
pack appears under the app's **Background Assets**; attach it to the build.

(Scriptable alternative: the App Store Connect API endpoints
`/v1/backgroundAssets` → `/v1/backgroundAssetVersions` →
`/v1/backgroundAssetUploadFiles`.)

Re-uploading a new model = a new **version** of the same `qwen7b-q4` pack.

---

## Test on-device BEFORE TestFlight (mock server)

Apple-hosted packs normally only resolve for TestFlight/App Store builds. For a
dev build, serve the pack locally:

```bash
# Mac and iPhone on the same wifi. Use the Mac's LAN IP.
xcrun ba-serve --asset-pack build/qwen7b-q4.aar --host 192.168.1.XXX
```

On the iPhone: **Settings → Developer → Background Assets Development Overrides**
→ point it at the printed `ba-serve` URL. Now `AssetPackManager` in a dev build
downloads from your Mac.

---

## What the app does (already wired in code)

`ModelDownloader` (kept the same name/interface) now calls `AssetPackManager`:
`assetPack(withID:)` → observe `statusUpdates(...)` for progress →
`ensureLocalAvailability(of:)`. The model file path handed to llama.cpp comes
from `descriptor(for:)` + `fcntl(F_GETPATH)`. The Settings "Download" button and
progress bar are unchanged.
