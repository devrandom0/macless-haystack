import json
import threading

import pytest
from http.client import HTTPConnection
from http.server import HTTPServer

import mh_endpoint


@pytest.fixture
def server():
    mh_endpoint.apple_session_stale = False

    httpd = HTTPServer(('127.0.0.1', 0), mh_endpoint.ServerHandler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield httpd
    finally:
        httpd.shutdown()
        thread.join()
        mh_endpoint.apple_session_stale = False


def _post(server, path, body):
    conn = HTTPConnection('127.0.0.1', server.server_port)
    conn.request('POST', path, body=json.dumps(body), headers={'Content-Type': 'application/json'})
    response = conn.getresponse()
    data = response.read()
    conn.close()
    return response.status, json.loads(data) if data else None


def test_post_fetch_reports_apple_session_stale_false_when_session_is_fine(server, monkeypatch):
    monkeypatch.setattr(mh_endpoint.history_archiver, "fetch_reports_with_cache", lambda *a, **k: ([], 0))

    status, body = _post(server, '/', {"ids": ["hash-a"], "days": 7})

    assert status == 200
    assert body == {"results": [], "new_count": 0, "appleSessionStale": False}


def test_post_fetch_reports_apple_session_stale_true_when_flag_is_set(server, monkeypatch):
    # The live fetch inside fetch_reports_with_cache already flipped the
    # flag (e.g. it fell back to cache after a 401), so it's set by the
    # time do_POST builds the response.
    def fake_fetch(*a, **k):
        mh_endpoint.apple_session_stale = True
        return ([], 0)

    monkeypatch.setattr(mh_endpoint.history_archiver, "fetch_reports_with_cache", fake_fetch)

    status, body = _post(server, '/', {"ids": ["hash-a"], "days": 7})

    assert status == 200
    assert body == {"results": [], "new_count": 0, "appleSessionStale": True}


def test_post_fetch_returns_503_apple_session_expired_when_no_cache_fallback(server, monkeypatch):
    def fake_fetch(*a, **k):
        mh_endpoint.apple_session_stale = True
        raise Exception("401 Client Error")

    monkeypatch.setattr(mh_endpoint.history_archiver, "fetch_reports_with_cache", fake_fetch)

    status, body = _post(server, '/', {"ids": ["hash-a"], "days": 7})

    assert status == 503
    assert body == {"error": "apple_session_expired"}

