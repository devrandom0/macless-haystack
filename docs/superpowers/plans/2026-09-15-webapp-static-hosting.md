# Webapp Static Hosting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the Flutter web build of macless_haystack from the existing endpoint server under `/webapp/`, on the same origin, port, and Basic Auth as the API.

**Architecture:** A new pure-logic module (`endpoint/web_static.py`) resolves a request path to a file inside a `web_dist` directory, with traversal protection. `mh_endpoint.py`'s `do_GET` gets one new branch that uses it, after the existing auth check. A multi-stage Dockerfile builds the Flutter web app in a Flutter-SDK stage and copies the output into the existing Python runtime stage as `endpoint/web_dist`, so it's present whenever the image is built this way.

**Tech Stack:** Python 3.12 stdlib only (`pathlib`, `mimetypes`, `urllib.parse`) for the server side; `pytest` for tests; Docker multi-stage build with `ghcr.io/cirruslabs/flutter:stable` as the build stage.

**Spec:** `docs/superpowers/specs/2026-09-15-webapp-static-hosting-design.md`

## Global Constraints

- Web app is served at `/webapp/` on the same origin as the API - no new port, domain, or CORS configuration.
- The existing `authenticate()` check in `do_GET` must run before any `/webapp` request is served - Basic Auth already configured for the API protects the web app for free.
- `Cache-Control: no-cache` on every file served under `/webapp`.
- Traversal protection must reject both plain (`../`) and URL-encoded (`%2e%2e/`) escape attempts, verified by resolving the final path and checking containment - never by string-matching `..`.
- If `endpoint/web_dist` doesn't exist (an image built without the Flutter stage), every `/webapp/*` request 404s; no exception, no crash, and the API paths are unaffected.
- No changes to any existing API path's behavior or existing tests.

---

### Task 1: `endpoint/web_static.py` - path resolution and content type

**Files:**
- Create: `endpoint/web_static.py`
- Test: `endpoint/tests/test_web_static.py`

**Interfaces:**
- Produces: `resolve_static_path(request_path: str, web_root: Path) -> Path | None` - resolves a request path under `/webapp` to an existing file inside `web_root`, or `None`.
- Produces: `guess_content_type(path: Path) -> str` - best-effort MIME type, falling back to `application/octet-stream`.

- [ ] **Step 1: Write the failing tests**

Create `endpoint/tests/test_web_static.py`:

```python
from pathlib import Path

import pytest

from web_static import resolve_static_path, guess_content_type


@pytest.fixture
def web_root(tmp_path):
    (tmp_path / "index.html").write_text("<html>home</html>")
    (tmp_path / "main.dart.js").write_text("// js")
    sub = tmp_path / "assets"
    sub.mkdir()
    (sub / "AssetManifest.json").write_text("{}")
    return tmp_path


def test_root_with_trailing_slash_resolves_to_index(web_root):
    result = resolve_static_path("/webapp/", web_root)
    assert result is not None
    assert result.read_text() == "<html>home</html>"


def test_root_without_trailing_slash_resolves_to_index(web_root):
    result = resolve_static_path("/webapp", web_root)
    assert result is not None
    assert result.read_text() == "<html>home</html>"


def test_resolves_a_top_level_file(web_root):
    result = resolve_static_path("/webapp/main.dart.js", web_root)
    assert result is not None
    assert result.read_text() == "// js"


def test_resolves_a_nested_file(web_root):
    result = resolve_static_path("/webapp/assets/AssetManifest.json", web_root)
    assert result is not None
    assert result.read_text() == "{}"


def test_rejects_traversal_outside_web_root(web_root):
    result = resolve_static_path("/webapp/../../../../etc/passwd", web_root)
    assert result is None


def test_rejects_url_encoded_traversal(web_root):
    result = resolve_static_path("/webapp/%2e%2e/%2e%2e/etc/passwd", web_root)
    assert result is None


def test_rejects_a_directory_path(web_root):
    result = resolve_static_path("/webapp/assets", web_root)
    assert result is None


def test_returns_none_for_a_missing_file(web_root):
    result = resolve_static_path("/webapp/does-not-exist.js", web_root)
    assert result is None


def test_returns_none_for_a_path_outside_webapp_prefix(web_root):
    result = resolve_static_path("/history/devices", web_root)
    assert result is None


def test_returns_none_when_web_root_does_not_exist(tmp_path):
    result = resolve_static_path("/webapp/", tmp_path / "never-built")
    assert result is None


def test_guess_content_type_known_extensions():
    assert guess_content_type(Path("main.dart.js")) == "text/javascript"
    assert guess_content_type(Path("app.wasm")) == "application/wasm"
    assert guess_content_type(Path("manifest.json")) == "application/json"
    assert guess_content_type(Path("index.html")) == "text/html"


def test_guess_content_type_unknown_extension_falls_back():
    assert guess_content_type(Path("mystery.xyz")) == "application/octet-stream"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd endpoint && python3 -m pytest tests/test_web_static.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'web_static'`

- [ ] **Step 3: Write the implementation**

Create `endpoint/web_static.py`:

```python
import mimetypes
from pathlib import Path
from urllib.parse import unquote

WEBAPP_PREFIX = '/webapp'


def resolve_static_path(request_path, web_root):
    """Resolves `request_path` (expected to start with WEBAPP_PREFIX) to an
    existing file inside `web_root`.

    Returns None if the path doesn't start with WEBAPP_PREFIX, if it
    escapes web_root (via plain or URL-encoded `..` segments - checked by
    resolving the final path and verifying containment, not by
    string-matching `..`, since encoded or normalized traversal sequences
    can slip past a naive string check), or if it doesn't point at an
    existing file.
    """
    if not request_path.startswith(WEBAPP_PREFIX):
        return None

    remainder = unquote(request_path[len(WEBAPP_PREFIX):]).lstrip('/')
    if remainder == '':
        remainder = 'index.html'

    web_root_resolved = Path(web_root).resolve()
    candidate = (web_root_resolved / remainder).resolve()

    if not candidate.is_relative_to(web_root_resolved):
        return None
    if not candidate.is_file():
        return None
    return candidate


def guess_content_type(path):
    """Best-effort MIME type for `path`, falling back to a generic binary
    type for anything mimetypes doesn't recognize.
    """
    content_type, _ = mimetypes.guess_type(str(path))
    return content_type or 'application/octet-stream'
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd endpoint && python3 -m pytest tests/test_web_static.py -v`
Expected: PASS, all 11 tests

- [ ] **Step 5: Commit**

```bash
git add endpoint/web_static.py endpoint/tests/test_web_static.py
git commit -m "feat: add static path resolution for the /webapp route"
```

---

### Task 2: Wire `/webapp` into `mh_endpoint.py`'s `do_GET`

**Files:**
- Modify: `endpoint/mh_endpoint.py`
- Test: `endpoint/tests/test_mh_endpoint_webapp.py`

**Interfaces:**
- Consumes: `web_static.resolve_static_path(request_path: str, web_root: Path) -> Path | None`, `web_static.guess_content_type(path: Path) -> str` (Task 1).
- Produces: `mh_endpoint.WEB_ROOT` (module-level `Path` constant, monkeypatchable in tests) and `ServerHandler._serve_static(self, path: str) -> None`.

- [ ] **Step 1: Write the failing tests**

Create `endpoint/tests/test_mh_endpoint_webapp.py`:

```python
import threading

import pytest
from http.client import HTTPConnection
from http.server import HTTPServer

import mh_config
import mh_endpoint


@pytest.fixture
def server():
    httpd = HTTPServer(('127.0.0.1', 0), mh_endpoint.ServerHandler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield httpd
    finally:
        httpd.shutdown()
        thread.join()


@pytest.fixture
def no_auth(monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: None)
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: None)
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {})


@pytest.fixture
def web_root(tmp_path, monkeypatch):
    (tmp_path / "index.html").write_text("<html>webapp</html>")
    (tmp_path / "main.dart.js").write_text("// js")
    monkeypatch.setattr(mh_endpoint, "WEB_ROOT", tmp_path)
    return tmp_path


def _get(server, path):
    conn = HTTPConnection('127.0.0.1', server.server_port)
    conn.request('GET', path)
    response = conn.getresponse()
    body = response.read()
    conn.close()
    return response, body


def test_serves_index_html_at_webapp_root(server, no_auth, web_root):
    response, body = _get(server, '/webapp/')
    assert response.status == 200
    assert body == b"<html>webapp</html>"
    assert response.getheader('Content-type') == 'text/html'


def test_serves_a_nested_asset_with_correct_content_type(server, no_auth, web_root):
    response, body = _get(server, '/webapp/main.dart.js')
    assert response.status == 200
    assert body == b"// js"
    assert response.getheader('Content-type') == 'text/javascript'


def test_sets_no_cache_header(server, no_auth, web_root):
    response, _ = _get(server, '/webapp/')
    assert response.getheader('Cache-Control') == 'no-cache'


def test_returns_404_for_a_missing_file(server, no_auth, web_root):
    response, _ = _get(server, '/webapp/does-not-exist.js')
    assert response.status == 404


def test_returns_404_when_web_dist_does_not_exist(server, no_auth, monkeypatch, tmp_path):
    monkeypatch.setattr(mh_endpoint, "WEB_ROOT", tmp_path / "never-built")
    response, _ = _get(server, '/webapp/')
    assert response.status == 404


def test_webapp_requires_authentication_when_configured(server, web_root, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: "simo")
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: "hunter2")
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {})

    response, _ = _get(server, '/webapp/')
    assert response.status == 401
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd endpoint && python3 -m pytest tests/test_mh_endpoint_webapp.py -v`
Expected: FAIL - `test_webapp_requires_authentication_when_configured` passes already (existing auth check), every other test fails with 200-vs-something-else or `AttributeError: module 'mh_endpoint' has no attribute 'WEB_ROOT'`

- [ ] **Step 3: Write the implementation**

In `endpoint/mh_endpoint.py`, add the import near the other local module imports (after `from register import apple_cryptography, pypush_gsa_icloud`):

```python
import web_static
```

Add `from pathlib import Path` to the existing `import` block at the top (alongside `import base64`, `import json`, etc.).

Add the `WEB_ROOT` constant near the other module-level globals (after `history_encryption_key = None`):

```python
WEB_ROOT = Path(__file__).resolve().parent / 'web_dist'
```

In `do_GET`, add the new branch right after the auth check and `path = urlparse(self.path).path` line, before the existing `if path == '/history/devices':` check:

```python
        if path.startswith('/webapp'):
            self._serve_static(path)
            return

```

Add the `_serve_static` method to `ServerHandler` (placed right after `do_GET`, before `do_POST`):

```python
    def _serve_static(self, path):
        try:
            resolved = web_static.resolve_static_path(path, WEB_ROOT)
            data = resolved.read_bytes() if resolved is not None else None
        except OSError as e:
            logger.warning(f"Error serving static file for {path}: {e}")
            self.send_response(500)
            self.addCORSHeaders()
            self.end_headers()
            return

        if data is None:
            self.send_response(404)
            self.addCORSHeaders()
            self.end_headers()
            return

        self.send_response(200)
        self.addCORSHeaders()
        self.send_header('Content-type', web_static.guess_content_type(resolved))
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(data)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd endpoint && python3 -m pytest tests/test_mh_endpoint_webapp.py -v`
Expected: PASS, all 6 tests

- [ ] **Step 5: Run the full existing test suite to confirm no regression**

Run: `cd endpoint && python3 -m pytest tests/ -v`
Expected: PASS, every existing test plus the new ones from Task 1 and this task

- [ ] **Step 6: Commit**

```bash
git add endpoint/mh_endpoint.py endpoint/tests/test_mh_endpoint_webapp.py
git commit -m "feat: serve the web app under /webapp, gated by existing Basic Auth"
```

---

### Task 3: Multi-stage Docker build producing the web app

**Files:**
- Modify: `endpoint/Dockerfile`
- Create: `.dockerignore` (repo root)
- Delete: `endpoint/.dockerignore` (superseded - Docker only reads `.dockerignore` from the build context root, and the context is moving from `endpoint/` to the repo root)
- Modify: `docker-compose.yaml`
- Modify: `.github/workflows/dev-docker-image.yaml`

**Interfaces:**
- Consumes: nothing from Tasks 1-2 directly - this wires the *build*, not the server code. Depends on `endpoint/web_dist` being the path Task 2's `WEB_ROOT` points at (already true: `Path(__file__).resolve().parent / 'web_dist'` inside the container is `/app/endpoint/web_dist`).
- Produces: a Docker image with `/app/endpoint/web_dist/index.html` present, and CI/compose configuration that builds it correctly with the new (repo-root) build context.

This task has no unit tests of its own - "tests" are direct verification via `docker build` and inspecting the resulting image, since there's no Python/Dart code being added here, only build configuration. No network access to the real deployment server (192.168.99.72) exists from this environment - final live verification is the user's responsibility after they pull and rebuild there.

- [ ] **Step 1: Rewrite `endpoint/Dockerfile` as multi-stage**

Replace the entire contents of `endpoint/Dockerfile` with:

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

- [ ] **Step 2: Add a root `.dockerignore` and remove the old one**

The build context is moving from `endpoint/` to the repo root, so the `.dockerignore` Docker actually reads has to move too - `endpoint/.dockerignore` at its current location will no longer apply and would silently stop excluding anything (including `endpoint/data/*.db`/`*.json` files that may contain private keys - this must not regress).

Delete `endpoint/.dockerignore`.

Create `.dockerignore` at the repo root:

```
.git/
docs/
firmware/
images/
scripts/
.claude/
.superpowers/
*.md

endpoint/venv/
endpoint/__pycache__/
endpoint/**/__pycache__/
endpoint/.pytest_cache/
endpoint/tests/
endpoint/requirements-dev.txt
endpoint/Dockerfile*
endpoint/data/*.json
endpoint/data/*.db
endpoint/data/*.bin

macless_haystack/build/
macless_haystack/.dart_tool/
macless_haystack/android/.gradle/
```

- [ ] **Step 3: Build the image locally and verify**

Run from the repo root: `docker build -f endpoint/Dockerfile -t macless-haystack-webapp-test .`
Expected: build succeeds (the Flutter SDK stage pull + `flutter pub get`/`flutter build web` will take several minutes on first run - this is expected, not a failure).

Then verify the web build landed in the right place and nothing sensitive leaked into the context:

```bash
docker run --rm --entrypoint sh macless-haystack-webapp-test -c \
  "test -f endpoint/web_dist/index.html && test -f endpoint/web_dist/main.dart.js && test ! -d endpoint/tests && test ! -d .git && echo VERIFIED"
```

Expected output: `VERIFIED`

Clean up the test image: `docker rmi macless-haystack-webapp-test`

- [ ] **Step 4: Add the `build:` section to `docker-compose.yaml`**

In `docker-compose.yaml`, under the `macless-haystack` service, add a `build:` key alongside the existing `image:` (Compose uses `build` - and tags the result as `image` - whenever `docker compose build` is run explicitly; a plain `docker compose up` without a prior build still just pulls `image`):

```yaml
  macless-haystack:
    image: moghaddas/macless-haystack:dev
    build:
      context: .
      dockerfile: endpoint/Dockerfile
    container_name: macless-haystack
    restart: unless-stopped
    depends_on:
      - anisette
    ports:
      - "6176:6176"
    volumes:
      - mh_data:/app/endpoint/data
    stdin_open: true
    tty: true
```

Verify the YAML is well-formed:

```bash
python3 -c "import yaml; yaml.safe_load(open('docker-compose.yaml'))" && echo OK
```

Expected output: `OK`

- [ ] **Step 5: Update the CI workflow's build context**

In `.github/workflows/dev-docker-image.yaml`, change the `Build and push docker image` step's `context` and add an explicit `file`:

```yaml
      - name: Build and push docker image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ./endpoint/Dockerfile
          platforms: linux/amd64,linux/arm64
          push: true
          tags: moghaddas/macless-haystack:dev,moghaddas/macless-haystack:dev-${{ github.sha }}
```

Verify the YAML is well-formed:

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/dev-docker-image.yaml'))" && echo OK
```

Expected output: `OK`

- [ ] **Step 6: Commit**

```bash
git add endpoint/Dockerfile .dockerignore docker-compose.yaml .github/workflows/dev-docker-image.yaml
git rm endpoint/.dockerignore
git commit -m "build: bake the Flutter web build into the endpoint image"
```

---

## Manual verification (user, on the real server)

This environment has no network access to 192.168.99.72. Once this branch is merged and pushed:

1. `git pull` on the server, then `docker compose build && docker compose up -d` (or wait for the CI-pushed `:dev` image and `docker compose pull && docker compose up -d`).
2. Visit `https://mytags.openinfrastructure.ir/webapp/` - expect the Basic Auth prompt (if configured) followed by the app loading.
3. Confirm the app's own API calls (login, accessory list, history) still work from inside the web app, same-origin.
