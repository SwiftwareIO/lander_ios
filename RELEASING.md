# Releasing the iOS SDK

The SDK lives in the Lander monorepo at `sdk/lander_ios`. Apps install it from the public, read only mirror [github.com/SwiftwareIO/lander_ios](https://github.com/SwiftwareIO/lander_ios): Swift Package Manager resolves versions from the mirror's git tags (bare semver such as `0.1.0`), and the `LanderSDK` podspec points at the same tags. Never commit to the mirror directly.

`.github/workflows/sdk-ios-release.yml` keeps the mirror in step:

- **On every push to `main`** that touches `sdk/lander_ios`, it pushes the SDK folder (a `git subtree split`) to the mirror's `main`. It can also be run by hand from the Actions tab.
- **On a monorepo tag `ios-vX.Y.Z`**, it checks that the tag matches the version in the source, the podspec and the changelog, runs `swift test`, pushes the tag `X.Y.Z` to the mirror and optionally publishes the pod to CocoaPods trunk if a trunk token is configured.

The current public distribution is Swift Package Manager. `LanderSDK` is not published to CocoaPods trunk.

## One-time setup

1. **Deploy key for the mirror.** Create a key pair without a passphrase:

   ```bash
   ssh-keygen -t ed25519 -N '' -C 'lander monorepo to lander_ios' -f lander_ios_deploy
   ```

   - In `SwiftwareIO/lander_ios`, Settings, Deploy keys, add `lander_ios_deploy.pub` and tick **Allow write access**.
   - In `SwiftwareIO/lander`, Settings, Secrets and variables, Actions, add the private key `lander_ios_deploy` as the secret `SDK_MIRROR_IOS_DEPLOY_KEY`.
   - Delete both files from your machine.

   Without this secret the mirror job is skipped with a notice and a release fails before doing anything.

2. **Optional CocoaPods trunk setup (not configured).** Register once (this sends a confirmation email), then click the link in it:

   ```bash
   pod trunk register team@golander.link 'Lander' --description='lander release CI'
   ```

   Copy the token from `~/.netrc` (the `password` of the `trunk.cocoapods.org` entry) and save it in `SwiftwareIO/lander` as the secret `COCOAPODS_TRUNK_TOKEN`. The first `pod trunk push` claims the `LanderSDK` name for that account; add other owners with `pod trunk add-owner LanderSDK <email>`.

   Without this secret the release still pushes the tag (so Swift Package Manager gets the version) and skips the pod with a notice.

3. **First mirror push.** Run the workflow once from the Actions tab (`workflow_dispatch`) after merging, so the mirror's `main` exists before the first release.

## Each release

1. In a pull request, bump the version in all three places and describe the changes:
   - `landerSDKVersion` in `Sources/Lander/Support.swift`
   - `s.version` in `LanderSDK.podspec`
   - a `## X.Y.Z` heading in `CHANGELOG.md`

   Update `apps/docs/content/docs/ios/changelog.mdx` too, and any docs the change affects.
2. Merge it to `main`. The mirror's `main` updates on its own.
3. Tag the merge commit and push the tag:

   ```bash
   git checkout main && git pull
   git tag ios-vX.Y.Z
   git push origin ios-vX.Y.Z
   ```

4. Watch the "iOS SDK release" run. When it is green, `.package(url: "https://github.com/SwiftwareIO/lander_ios", from: "X.Y.Z")` resolves the new version. CocoaPods only resolves it if the optional trunk publication was configured and completed.

If the version check fails, delete the monorepo tag (`git push origin :refs/tags/ios-vX.Y.Z`), fix the versions in a pull request and tag again. The workflow never moves a tag that already exists on the mirror, and published pods cannot be overwritten: release a new patch version instead.

`pod lib lint LanderSDK.podspec` works any time. `pod spec lint` (and `pod trunk push`) fetch the source from the mirror's tag, so they only pass once the tag `X.Y.Z` exists there, which is why the workflow pushes the tag first.
