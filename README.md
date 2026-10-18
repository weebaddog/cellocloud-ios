# CelloCloud for iPhone

Native SwiftUI app for CelloCloud (https://cloud.cellosig.com): end-to-end encrypted files and photos.
Same encryption as the website and the Android app; the server never sees names or contents.

- `Core/` — Swift package `CelloCloudCore` (PBKDF2/HKDF/AES-GCM, recovery key text). `swift test`.
- `Interop/` — `vectors.mjs` runs the website's crypto (`web-crypto.js`, a copy of `cellocloud/web/crypto.js`)
  to prove both directions match. Keep `web-crypto.js` in sync with the website.
- `App/` — the app: sign in / up / recover, Files (folders, upload any file, rename, move, delete, open via QuickLook),
  Photos (grid by month), camera backup (new photos → "Camera backup" folder; BGProcessingTask), Settings.
- `project.yml` — XcodeGen spec. No Mac needed: GitHub Actions builds it (`.github/workflows/ios.yml`).

The `sideload` job makes `cellocloud-sideload.ipa` (bundle id `com.cellocloud.sideload`) to install with Sideloadly.