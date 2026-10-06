# Apple App Site Association (AASA) Reference

This directory contains a **reference template** for the `apple-app-site-association` file required for Universal Links / OAuth callback.

## Live File Location

The actual live file for the default OAuth redirect URI is **NOT** hosted in this repository. It is hosted at:

**https://pmnewell.com/.well-known/apple-app-site-association**

This file is maintained in the `pmn4/pmn4.github.io` repository (Patrick's site repository).

## Using This Template

If you are hosting your own custom domain for OAuth:

1. Copy `apple-app-site-association` from this directory
2. Replace `<TEAMID>` with your Apple Developer Team ID (found in Xcode: Scout target > Signing & Capabilities > Team)
3. Update the bundle ID if you've changed it from `com.pmnewell.falsepositivescout`
4. Host the file at `https://yourdomain.com/.well-known/apple-app-site-association`
5. Ensure:
   - Served over HTTPS with valid certificate
   - Content-Type is `application/json` or `application/pkcs7-mime`
   - No file extension (`.json` suffix not allowed)
   - Returns HTTP 200 (not 404 or redirect)

## Format Notes

- The `appID` format is `<TEAMID>.<bundle-identifier>`
- If you have no Team ID yet, the placeholder `<TEAMID>` will need to be replaced before the file works
- The `paths` array must include the OAuth callback path: `/false-positive-scout/oauth/callback`
- The wildcard `/*` suffix ensures query parameters are matched
