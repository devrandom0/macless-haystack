# Auth-expiry visibility, per-device refresh, SMS/voice 2FA fallback

Base: `sina/dev`. Three independent branches, merged back into `sina/dev` after review.

## 1. Surface an expired Apple session (`sina/apple_session_expiry_banner`)

Root cause: `history/archiver.py` `fetch_reports_with_cache` swallows a failed live Apple
fetch and returns cached reports with HTTP 200. An expired token (401/403 from Apple) sets
`apple_session_stale` in `mh_endpoint.py`, but only the Settings page reads it via
`/auth/apple/status`. Locations silently stop updating.

- Endpoint: the fetch response (`POST /`) gains `"appleSessionStale": bool`.
  `_raise_for_status_marking_stale` clears the flag after a successful Apple response.
  When there's no cache to fall back on and the live call fails on auth, respond
  `503 {"error": "apple_session_expired"}` instead of the generic 501.
- App: `ReportsFetcher` exposes the flag (or throws a typed `AppleSessionExpiredException`
  for the 503). Dashboard shows a persistent `MaterialBanner`: "Apple ID login expired,
  locations are not updating" with a Re-login action that opens `AppleAuthPage`. Also
  checks `/auth/apple/status` on launch and app resume. An endpoint without the status
  route (404/older server) is ignored silently. The banner clears after a successful login.

## 2. Discoverable per-device refresh (`sina/per_device_refresh_button`)

Swipe-right Refresh on an accessory row already exists but is hidden. Add a Refresh
action where a user looks at one device: the accessory history page app bar and, if it
has an action area, the map marker popup. Reuse the existing single-accessory
`loadLocationUpdates(accessory)` path. Long-press is taken by drag-reorder, don't use it.

## 3. SMS / voice 2FA fallback (`sina/sms_voice_2fa_fallback`)

Apple returns `trustedDeviceSecondaryAuth` for any account with an Apple device, so the
app only offers the trusted-device code. The same identity token can request a phone code
(same approach as FindMy.py):

- list numbers: `GET https://gsa.apple.com/auth` `boot_args` (handle both
  `direct.phoneNumberVerification` and `direct.twoSV.phoneNumberVerification`)
- trigger: `PUT https://gsa.apple.com/auth/verify/phone/` `{"phoneNumber":{"id":N},"mode":"sms"|"voice"}`
- submit: existing `POST .../auth/verify/phone/securitycode` with matching `mode`

Endpoint: `POST /auth/apple/resend {"mode": "sms"|"voice"}` against the pending login,
switches it to the phone method, returns `{"status":"code_required","method":"sms"|"voice","phone":"<masked>"}`.
App: "Text me instead" / "Call me instead" on the code step, disabled for 30s after use.
Unverified against a real account, needs a live test before it's trusted.
