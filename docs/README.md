# OAuth Relay and AASA Reference

## OAuth Custom URL Scheme Relay (Current Setup)

Scout uses a **custom URL scheme relay** for OAuth, which works with **free Apple Personal Teams** (no paid developer account required).

### How It Works

1. App starts OAuth with redirect URI: `https://pmnewell.com/false-positive-scout/oauth/callback`
2. User signs in to Roboflow, which redirects to the https:// URL
3. A static relay page at that URL **immediately forwards** to: `scout://oauth/callback?code=...&state=...` (preserving all query parameters)
4. iOS opens Scout via the `scout://` custom URL scheme
5. App validates state (PKCE) and exchanges code for tokens

**No Universal Links required. No Associated Domains capability required. No AASA file required.**

The relay page is maintained in the `pmn4/pmn4.github.io` repository (Patrick's site repository).

### Relay Contract

- **Scheme:** `scout`
- **Path:** `/oauth/callback`
- **Forwarded Parameters:** All query parameters from the https:// callback are preserved:
  - `code` - Authorization code
  - `state` - CSRF token
  - `error` - Error code (if authorization failed)
  - `error_description` - Human-readable error message

## AASA Template (Optional / Unused)

The `apple-app-site-association` file in this directory is **NOT used** by the current OAuth setup. It is kept as a reference template for future Universal Links setup if upgrading to a paid Apple Developer Program account.

### If You Want Universal Links (Paid Account Only)

If you have a paid Apple Developer Program account and want to use Universal Links instead of the custom URL scheme relay:

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
