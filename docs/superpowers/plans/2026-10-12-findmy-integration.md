# FindMy Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the `findmy` library into the Python endpoint and connect it to the Flutter frontend so both official Apple devices (AirTags, iPhones, etc.) and custom OpenHaystack beacons can be authenticated, fetched, and plotted on the map.

**Architecture:** 
1. The backend endpoint incorporates `findmy` (`pip install findmy`) alongside the existing anisette service connection. It adds endpoints for Apple ID authentication/session checks (`/api/auth/login`, `/api/auth/2fa`, `/api/auth/status`), listing all devices (`GET /api/devices`), and fetching current/historical device location reports (`POST /api/reports`).
2. The Flutter frontend gains an Apple ID account management/login interface in settings, queries `/api/devices` to fetch all account devices, and automatically syncs their decrypted locations to the dashboard and map.

**Tech Stack:** Python 3 (FastAPI/BaseHTTP + `findmy`), Flutter / Dart (Provider, flutter_map, flutter_settings_screens).

---

## Global Constraints
- Python 3.10+ compatibility.
- Retain backwards compatibility with existing DIY OpenHaystack key imports and `/` POST report requests.
- No hardcoded secrets or credentials.

---

### Task 1: Backend `findmy` Integration & Dependency Setup
**Files:**
- Modify: `endpoint/requirements.txt`
- Modify: `endpoint/Dockerfile`
- Test: `endpoint/test_findmy_service.py`

- [x] Add `findmy` to `endpoint/requirements.txt`.
- [x] Create a `FindMyService` helper class wrapping `findmy` account login, 2FA submission, and device/report retrieval.
- [x] Write unit tests for `FindMyService` mocking the `findmy` client calls.
- [x] Run tests and verify success.

### Task 2: Backend REST Endpoints for Device Discovery & Auth
**Files:**
- Modify: `endpoint/mh_endpoint.py`
- Test: `endpoint/test_endpoint_api.py`

- [x] Expose `GET /api/devices` to return all discovered devices and accessories.
- [x] Expose `POST /api/auth/login` and `POST /api/auth/2fa` to support signing in via app credentials.
- [x] Expose `POST /api/reports` to retrieve location reports for both official devices and DIY keys.
- [x] Write integration tests verifying response serialization and error handling.
- [x] Run tests and verify success.

### Task 3: Frontend Client Integration for Account Devices & Map Rendering
**Files:**
- Modify: `macless_haystack/lib/findMy/reports_fetcher.dart`
- Modify: `macless_haystack/lib/accessory/accessory_registry.dart`
- Modify: `macless_haystack/lib/preferences/preferences_page.dart`
- Test: `macless_haystack/test/accessory/accessory_registry_test.dart`

- [x] Add Apple ID login and 2FA dialog triggers in `preferences_page.dart`.
- [x] Extend `AccessoryRegistry` to load devices from `GET /api/devices` in addition to local JSON imports.
- [x] Map discovered Apple devices to `AccessoryModel` items so they render seamlessly on the dashboard and map.
- [x] Run Flutter tests and verify success.
