# Releasing

## 1. Bump the version

Edit `VERSION` (for example `1.0.1`) and commit.

## 2. Build

```sh
scripts/test.sh
scripts/build-app.sh
```

This produces `dist/AnnePro.app`, `dist/AnnePro-<version>.zip` and `dist/anne-<version>.zip`, all universal (Apple Silicon + Intel).

The app is **ad-hoc signed**, not notarized. It runs fine on the machine that built it; other users approve it once in System Settings → Privacy & Security (see the README).

Notarizing would need a paid Apple Developer account, and for individuals the signing certificate shows the account holder's legal name. If that ever changes, `scripts/build-app.sh` accepts `SIGN_IDENTITY` and `NOTARY_PROFILE`.

## 3. Publish

Create a GitHub release tagged `v<version>` and attach both zips:

```sh
gh release create v$(cat VERSION) dist/AnnePro-$(cat VERSION).zip dist/anne-$(cat VERSION).zip --title "Anne Pro for Mac $(cat VERSION)" --notes "…"
```
