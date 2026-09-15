# Serving the Flutter web build from the endpoint server

## Motivation

The app is currently only reachable as a sideloaded Android APK. Flutter already supports a web target (`macless_haystack/web/`), but nothing builds or serves it. The user wants a permanent, publicly reachable web build of the app, hosted on their own infrastructure rather than a third-party static host, so it lives alongside the endpoint server they already run and is reachable through the tunnel they already have pointed at `mytags.openinfrastructure.ir`.

Goal: serve the Flutter web build from the same server/port/domain the API already uses, with no new tunnel or DNS configuration and no new CORS surface.

## Non-goals

- No changes to the mobile app or its build. This only adds a web deployment path alongside it.
- No new authentication mechanism. The web app is gated by whatever Basic Auth (`endpoint_user`/`endpoint_pass` or `[BasicAuthUsers]`) is already configured for the API - if none is configured, the web app is exactly as open as the API already is today.
- No CDN, aggressive caching, or build-hash-based cache-busting. Traffic is low (a personal server), so simplicity wins over cache performance.
- No feature flag to disable this at runtime. The web build is baked into the image at build time; if it's present, it's served. Removing the feature means rebuilding without it.

## Architecture

**URL space:** the web app is served under `/webapp/` on the existing endpoint port (6176, whatever domain/tunnel already forwards to it). `flutter build web --base-href=/webapp/` makes the build's own generated `index.html` and asset references resolve correctly under that prefix. Every existing API path (`/`, `/history/*`, `/auth/*`) is untouched - `/webapp` isn't a path any of them currently use.

**New module: `endpoint/web_static.py`**

- `resolve_static_path(request_path: str, web_root: Path) -> Path | None` - given a request path already known to start with `/webapp`, strips that prefix, defaults an empty remainder (or one ending in `/`) to `index.html`, resolves the result against `web_root`, and returns `None` unless the resolved path is both an existing file and still inside `web_root` (guards `..`-style traversal attempts, e.g. `/webapp/../../etc/passwd`). Resolution happens via `Path.resolve()` plus a containment check (`resolved.is_relative_to(web_root)`), not string matching on `..`, since encoded or normalized traversal sequences can slip past a naive string check.
- `guess_content_type(path: Path) -> str` - thin wrapper over `mimetypes.guess_type`, falling back to `application/octet-stream` for anything unrecognized (Flutter web output includes `.js`, `.wasm`, `.json`, `.png`, `.html`, `.css` - all standard, plus occasionally extensionless files it should still serve rather than reject).

**`mh_endpoint.py` change:** `do_GET` gets one new branch, checked after the existing `authenticate()` call (so Basic Auth already gates this) and before the current path-matching chain: if `path.startswith('/webapp')`, resolve and serve via the above, `404` on `None`. This is purely additive - no existing branch changes.

**Response headers:** `Cache-Control: no-cache` on every served file. A redeploy should never leave a client stuck on stale cached assets; the tradeoff (no caching benefit) is fine at this traffic scale.

## Data flow

1. Browser requests `https://mytags.openinfrastructure.ir/webapp/`.
2. Tunnel forwards to the container's port 6176, unchanged from today.
3. `do_GET` authenticates (existing Basic Auth prompt if configured), matches `/webapp`, resolves to `web_dist/index.html`, serves it.
4. The page's own script tags request `/webapp/main.dart.js`, `/webapp/assets/...`, etc. - same flow, same auth, same resolver.
5. The loaded app then talks to the API (`/`, `/history/*`) exactly as the mobile app does, at the same origin - no CORS involved since it's the same origin serving both.

## Docker build changes

This is the one structural change: **the build context has to widen from `endpoint/` to the repo root**, so the Dockerfile can see `macless_haystack/` at all.

`endpoint/Dockerfile` becomes multi-stage:

```dockerfile
FROM ghcr.io/cirruslabs/flutter:stable AS webbuild
WORKDIR /src
COPY macless_haystack macless_haystack
WORKDIR /src/macless_haystack
RUN flutter pub get && flutter build web --base-href=/webapp/

FROM python:3.12-slim
ENV TERM=xterm
WORKDIR /app
COPY endpoint/requirements.txt endpoint/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r endpoint/requirements.txt
COPY endpoint endpoint
COPY --from=webbuild /src/macless_haystack/build/web endpoint/web_dist
RUN useradd --create-home --shell /usr/sbin/nologin appuser \
    && chown -R appuser:appuser /app
USER appuser
CMD ["python", "-u", "endpoint/mh_endpoint.py"]
```

`docker-compose.yaml`'s `macless-haystack` service keeps its `image: moghaddas/macless-haystack:dev` tag but also gains a `build: {context: ., dockerfile: endpoint/Dockerfile}` section - Compose supports both together, using `build` (and tagging the result as `image`) whenever `docker compose build` is run explicitly, and falling back to pulling `image` on a plain `docker compose up` otherwise. This keeps `docker compose pull && docker compose up` working unchanged if `moghaddas/macless-haystack:dev` is produced by some external build/push pipeline this repo doesn't contain - but that external pipeline would need the same multi-stage Dockerfile and widened build context applied to it, which is outside what I can see or verify from here. Building locally now pulls a full Flutter SDK image as an intermediate stage - meaningfully heavier/slower than today's pure-Python build, acceptable for infrequent personal rebuilds.

`web_static.py` reads the web root as `Path(__file__).parent / 'web_dist'`, so a container built without that COPY step (e.g. someone building just the old context for API-only use) simply serves 404s under `/webapp` rather than crashing - the feature degrades gracefully if the build artifacts aren't present, without needing an explicit toggle.

## Error handling

- Requested file doesn't exist under `web_dist`, or the path resolves outside it → `404`, no traversal, no crash.
- `web_dist` directory itself missing entirely (old-style build) → every `/webapp/*` request 404s; API paths unaffected.
- Any other exception while resolving/reading a file → `500`, logged, never an unhandled exception that could crash the single-threaded `HTTPServer`.

## Testing

Extends the existing `endpoint/tests/` pattern (pytest, stdlib only):

- `resolve_static_path`: valid file resolves correctly; `/webapp/` and `/webapp` both default to `index.html`; `..`-based traversal attempts (plain and URL-encoded) are rejected; a path to a directory (not `index.html`) is rejected rather than silently listing it; a nonexistent file returns `None`.
- `guess_content_type`: known extensions map to their expected MIME type; unrecognized extensions fall back to `application/octet-stream`.
- `do_GET`'s new branch: an integration-style test (matching the existing `test_mh_endpoint_history_devices.py` pattern) confirming a request under `/webapp` is gated by the same `authenticate()` check as everything else, and that a valid request serves file bytes with the right content type.

No changes needed to any existing test - the new branch is purely additive and doesn't touch the API paths those tests cover.

Manual verification happens on the user's own server (192.168.99.72) after they pull and rebuild - this environment has no network access to that host.

## Follow-ups (explicitly out of scope here)

- Any cache-busting/content-hashing strategy beyond `no-cache`, if the no-caching tradeoff turns out to matter in practice.
- CI automation to rebuild/redeploy on push - this design covers the manual `docker compose build` + restart flow the user already uses for the API image.
