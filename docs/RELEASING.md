# Releasing

## Automatic (recommended)

1. Move the notes under **Unreleased** in `CHANGELOG.md` to a new `## x.y.z` heading, update `VERSION`, and commit.
2. Tag and push:

   ```sh
   git tag v$(cat VERSION) && git push origin main --tags
   ```

GitHub Actions (`.github/workflows/release.yml`) then tests, builds the universal app and CLI, and publishes the release with those changelog notes.

## Manual

```sh
scripts/test.sh
scripts/build-app.sh
gh release create v$(cat VERSION) dist/AnnePro-$(cat VERSION).zip dist/anne-$(cat VERSION).zip --title "Anne Pro for Mac $(cat VERSION)" --notes "…"
```

## Signing

The app is **ad-hoc signed**, not notarized. Users approve it once in System Settings → Privacy & Security (see the README).

Notarizing would need a paid Apple Developer account, and for individuals the signing certificate shows the account holder's legal name. If that ever changes, `scripts/build-app.sh` accepts `SIGN_IDENTITY` and `NOTARY_PROFILE`.
