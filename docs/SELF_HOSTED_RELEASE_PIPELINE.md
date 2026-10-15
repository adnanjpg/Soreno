# Soreno Self-Hosted macOS Release Pipeline

Date: 2026-04-28

This document captures the recommended release pipeline for Soreno using a self-hosted GitHub Actions runner on a trusted Mac, plus the credentials, hosting, and update/distribution decisions that go with it.

## 1. Summary

- Source repository stays **private** on GitHub.
- GitHub Actions runs on a **self-hosted macOS runner** installed on a trusted Mac.
- The runner builds the app locally on that Mac using the repo's existing packaging flow.
- CI signs and notarizes the app, creates a DMG, generates Sparkle update metadata, and uploads public artifacts to Cloudflare R2.
- The website and app both use a stable first-party download domain such as `download.soreno.app`.

## 2. Why This Setup

This is the best-fit setup for the current Soreno repo because:

- The app is currently packaged through a shell-based flow in [build.sh](../build.sh), not an Xcode archive pipeline.
- The app is built from a Swift Package target in [Package.swift](../Package.swift).
- The repo is **private**, so a public Cloudflare redirect to GitHub release assets is not suitable for end-user downloads.
- A self-hosted runner avoids GitHub macOS runner minute charges.

## 3. Final Architecture

```text
Private GitHub repo
        |
        | release/tag/manual trigger
        v
GitHub Actions workflow
        |
        | runs-on: self-hosted macOS runner
        v
Trusted Mac
  - checkout repo
  - build app
  - sign app
  - notarize app
  - create DMG
  - generate Sparkle appcast/signatures
        |
        | upload public artifacts
        v
Cloudflare R2 + custom domain
  - download.soreno.app/Soreno-latest.dmg
  - download.soreno.app/appcast.xml
  - versioned release files
        |
        +--> Website download button
        +--> App update feed (Sparkle)
```

## 4. Cost Comparison Snapshot

These are the practical cost conclusions from the current comparison we reviewed:

- **GitHub Actions, self-hosted runner**
  - GitHub does not charge hosted-runner minutes for self-hosted runners.
  - Cost is the Mac itself plus your time/maintenance.
  - Cheapest option if you already have access to a trusted Mac.

- **GitHub Actions, GitHub-hosted macOS**
  - Cheapest managed option for low-volume private-repo release builds.
  - Included free minutes depend on the GitHub plan.
  - Extra standard macOS minutes are billed beyond quota.

- **Xcode Cloud**
  - Can be competitively priced in low-to-medium volume scenarios.
  - Less natural fit for the current Soreno packaging flow because the repo does not currently use an Xcode-native archive/distribution pipeline.

- **Codemagic / Bitrise**
  - More managed mobile-CI platforms.
  - Usually more expensive than GitHub for a small private macOS desktop release pipeline.
  - Better chosen for CI ergonomics, not for lowest cost.

- **MacStadium**
  - Good if you want your own always-on dedicated Mac in the cloud.
  - More infrastructure and ops responsibility than needed right now.

## 5. Why Cloudflare Redirect Is Not Enough

A plain Cloudflare redirect to GitHub release assets is not appropriate for this repo because:

- The repo is private.
- GitHub release assets for private repositories are only available to users with read access to that repository.
- End users should not need GitHub access to download Soreno.

Therefore:

- **Do not** use `download.soreno.app -> github.com/.../releases/latest/download/...` for production downloads.
- **Do** publish the final public DMG and Sparkle feed to Cloudflare R2.

## 6. Trusted Mac Model

For this document, we assume:

- The runner Mac is effectively treated like your own machine.
- You trust the operator of that Mac.
- You are willing to place release credentials on that machine in a controlled way.

Even with that assumption, the cleaner setup is:

- Create a dedicated macOS user such as `soreno-ci`.
- Install the GitHub runner under that user.
- Store signing assets in a dedicated CI keychain, not in the everyday login keychain.
- Use the runner only for trusted branches/tags/releases.

## 7. What Credentials Are Needed

Running CI on your own or a trusted Mac does **not** remove the need for release credentials. It only changes where the job executes.

### 7.1 Credentials from GitHub

Usually automatic:

- `GITHUB_TOKEN`
  - Automatically provided by GitHub to each workflow job.
  - Used for repository-scoped operations in the same repo.
  - Can usually handle checkout, release creation/update, and release asset upload if workflow permissions are configured correctly.

Runner setup:

- Self-hosted runner registration token
  - Used one time when registering the runner.
  - Time-limited.
  - Not a long-term secret you keep in the workflow.

### 7.2 Credentials You Need for Production Releases

These are the important ones:

- **Developer ID Application certificate**
  - Exported as a `.p12`.
  - Needed for signing the macOS app.

- **Password for the exported `.p12`**
  - Needed to import the certificate into the CI keychain.

- **Apple notarization credentials**
  - Preferably an App Store Connect API key setup suitable for notarization.
  - Needed to submit the build to Apple for notarization and staple the ticket.

- **Sparkle private signing key**
  - Needed to sign Sparkle update metadata/releases.

- **Cloudflare R2 credentials**
  - Needed to upload the DMG and Sparkle appcast to your download bucket.

### 7.3 Credentials You Usually Do Not Need from the Mac Owner

If the runner is attached to your repo correctly, you generally do **not** need:

- Their GitHub personal password
- Their GitHub personal access token
- Their Apple Developer account credentials

What you may need from the Mac owner once:

- macOS admin access to install the runner as a service
- macOS admin access to create a dedicated CI user if needed

## 8. Secret Ownership and Storage

Recommended ownership model:

| Secret / Credential | Owned by | Stored where | Purpose |
|---|---|---|---|
| Runner registration token | GitHub / temporary | used once during runner setup | register runner |
| `GITHUB_TOKEN` | GitHub / automatic | injected per workflow job | repo operations |
| Developer ID `.p12` | You | imported into CI keychain on runner Mac | app signing |
| `.p12` password | You | GitHub Actions secret or local secure import step | unlock certificate import |
| App Store Connect API key | You | GitHub Actions secret and/or secure file on runner | notarization |
| Sparkle private key | You | runner Mac secure storage or GitHub secret material | Sparkle signing |
| Cloudflare R2 credentials | You | GitHub Actions secrets | artifact upload |

Preferred split:

- Put **repo/cloud** secrets in GitHub Actions secrets.
- Put **signing identities** in a dedicated CI keychain on the runner Mac.
- Avoid leaving certificate files around in the workspace after builds.

## 9. Recommended Secret Strategy

### Option A: Keep almost everything in GitHub secrets

Pros:

- Centralized
- Easier to rotate
- Easier to move to another runner later

Cons:

- Workflow must reconstruct/import sensitive files during each release build

### Option B: Keep signing assets on the runner Mac, cloud credentials in GitHub secrets

Pros:

- Better fit for macOS signing
- Fewer moving parts during the workflow

Cons:

- More runner-specific
- Harder to migrate quickly to a new machine

### Recommended approach for Soreno

Use a hybrid model:

- CI keychain on the runner stores:
  - Developer ID certificate
  - Sparkle private key if you choose local storage
- GitHub secrets store:
  - Cloudflare R2 credentials
  - Apple notarization API key material if you want workflow portability
  - Any workflow-level configuration values

## 10. Release Triggers

Recommended release triggers:

- `release.published` for production releases
- `workflow_dispatch` for manual test runs
- optional tag pattern for internal builds, such as `v*`

Recommended non-release policy:

- Do not run signing/notarization on every push.
- Do not run untrusted PR jobs on the self-hosted runner.
- Reserve the self-hosted runner for trusted release workflows only.

## 11. Release Flow

Recommended release flow:

1. Trigger workflow from GitHub Release publication or manual dispatch.
2. Run job on `self-hosted`, `macOS` runner.
3. Check out repository.
4. Build the app using the current packaging flow in [build.sh](../build.sh).
5. Sign the `.app` with your Developer ID certificate.
6. Notarize the app with Apple.
7. Staple notarization.
8. Create a distributable DMG.
9. Generate Sparkle appcast/signatures.
10. Upload versioned artifacts to Cloudflare R2.
11. Promote/copy the latest approved artifact to a stable path such as:
    - `Soreno-latest.dmg`
    - `appcast.xml`
12. Optionally attach the same artifacts to the GitHub Release for internal convenience.

## 12. Cloudflare Distribution Layout

Recommended R2 object layout:

```text
releases/
  latest/
    Soreno.dmg
    appcast.xml
  v1.0.0/
    Soreno.dmg
    appcast.xml
  v1.0.1/
    Soreno.dmg
    appcast.xml
```

Recommended public URLs:

- `https://download.soreno.app/Soreno-latest.dmg`
- `https://download.soreno.app/appcast.xml`
- `https://download.soreno.app/releases/v1.0.1/Soreno.dmg`

The website download button should point to the stable URL. Sparkle should use the stable appcast URL.

## 13. App Update Model

Recommended update model:

- Use Sparkle for in-app update discovery and delivery.
- Publish the Sparkle appcast from the same CI release workflow.
- Add a clear user-facing update path in the app:
  - `Update available`
  - `Download update`
  - `Restart to update` or `Relaunch to finish update`

This matches the release-pipeline roadmap item already tracked in [docs/ROADMAP.md](ROADMAP.md).

## 14. Security and Operational Risks

Main risks of a self-hosted runner:

- Workflow code executes on a persistent machine you control.
- Compromised workflow changes can execute arbitrary commands on that Mac.
- Release certificates and signing material expand the trust boundary of that machine.
- Workspace residue may persist between jobs if cleanup is incomplete.

Minimum safety rules:

- Use the runner only for a private repo.
- Restrict release workflows to trusted branches/tags/users.
- Use a dedicated macOS user for CI.
- Use a dedicated CI keychain for signing assets.
- Clean workspace/build artifacts after release jobs.
- Avoid running arbitrary PR jobs on this runner.

## 15. Setup Checklist

### macOS runner host

- [ ] Create dedicated macOS user `soreno-ci`
- [ ] Install Xcode / command line tools required by the build
- [ ] Install GitHub self-hosted runner
- [ ] Register runner to the Soreno repo
- [ ] Install runner as a background service
- [ ] Create CI keychain
- [ ] Import Developer ID certificate into CI keychain
- [ ] Configure codesign and notarization prerequisites

### GitHub

- [ ] Enable GitHub Actions for the repo
- [ ] Add workflow with `runs-on: [self-hosted, macOS]`
- [ ] Add repo secrets for Cloudflare and any workflow-managed Apple credentials
- [ ] Restrict release workflow triggers to trusted events
- [ ] Set workflow permissions for releases/assets as needed

### Cloudflare

- [ ] Create R2 bucket for release artifacts
- [ ] Create API credentials with minimal bucket-scoped access
- [ ] Attach custom domain `download.soreno.app`
- [ ] Configure cache behavior for DMG and appcast files

### App / website

- [ ] Point website download button to stable DMG URL
- [ ] Integrate Sparkle updater in the app
- [ ] Add in-app restart/relaunch update completion flow

## 16. Short Answer Reference

### Can GitHub Actions run on a trusted Mac we control?

Yes. A self-hosted runner on that Mac can execute GitHub Actions jobs for your private repo.

### Does that remove the need for release credentials?

No. You still need signing, notarization, update-signing, and artifact-upload credentials.

### Do we need the Mac owner's GitHub or Apple credentials?

Usually no. You mostly need machine access plus your own release credentials.

### Can we use a public Cloudflare redirect to a private GitHub release asset?

No. Private GitHub release assets are not suitable as anonymous end-user downloads.

### What should we use instead?

Publish the final public release artifacts to Cloudflare R2 on your own domain.

## 17. Sources

- GitHub self-hosted runners overview: https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners
- Adding self-hosted runners: https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners?apiVersion=2022-11-28
- Using self-hosted runners in workflows: https://docs.github.com/en/actions/hosting-your-own-runners/using-self-hosted-runners-in-a-workflow
- GitHub `GITHUB_TOKEN`: https://docs.github.com/actions/concepts/security/github_token
- GitHub Actions billing: https://docs.github.com/en/billing/managing-billing-for-github-actions/about-billing-for-github-actions
- GitHub Actions minute pricing: https://docs.github.com/en/billing/reference/actions-minute-multipliers
- GitHub releases access model: https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases
- GitHub release asset API: https://docs.github.com/en/rest/releases/assets?apiVersion=2022-11-28
- GitHub linking to releases: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases
- Apple App Store Connect API keys: https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api
- Apple API key creation details: https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api
- Cloudflare Workers pricing: https://developers.cloudflare.com/workers/platform/pricing/
- Cloudflare R2 pricing: https://developers.cloudflare.com/r2/pricing/
- Cloudflare redirect example: https://developers.cloudflare.com/workers/examples/redirect/
- Xcode Cloud pricing: https://developer.apple.com/xcode-cloud/get-started/
- Codemagic pricing: https://docs.codemagic.io/billing/pricing/
- Bitrise pricing: https://bitrise.io/pricing
- MacStadium pricing: https://macstadium.com/pricing
