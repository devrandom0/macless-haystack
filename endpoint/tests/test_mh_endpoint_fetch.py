import json
import threading
import time

import pytest
import requests
from http.client import HTTPConnection, RemoteDisconnected
from http.server import HTTPServer
from unittest.mock import MagicMock

import mh_config
import mh_endpoint
from history.store import HistoryStore


@pytest.fixture
def server(tmp_path, monkeypatch):
    monkeypatch.setattr(mh_config, "getConfigFile", lambda: str(tmp_path / "auth.json"))
    mh_endpoint.apple_session_stale = False
    mh_endpoint.history_store = None

    httpd = HTTPServer(('127.0.0.1', 0), mh_endpoint.ServerHandler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield httpd
    finally:
        httpd.shutdown()
        thread.join()
        mh_endpoint.apple_session_stale = False
        mh_endpoint.history_store = None


def _post(server, path, body):
    conn = HTTPConnection('127.0.0.1', server.server_port)
    conn.request('POST', path, body=json.dumps(body), headers={'Content-Type': 'application/json'})
    response = conn.getresponse()
    data = response.read()
    conn.close()
    return response.status, json.loads(data) if data else None


def _mock_apple_response(status_code, body=None):
    """Stands in for requests.post's Response, both as the return value
    and as the context manager fetch_from_apple opens it in
    (`with requests.post(...) as r:`)."""
    response = MagicMock()
    response.status_code = status_code
    response.content = json.dumps(body if body is not None else {"results": []}).encode()
    if status_code >= 400:
        response.raise_for_status.side_effect = requests.exceptions.HTTPError(response=response)
    else:
        response.raise_for_status.return_value = None
    response.__enter__.return_value = response
    response.__exit__.return_value = False
    return response


@pytest.fixture
def mock_apple_transport(monkeypatch):
    """Patches everything below fetch_from_apple's own logic - the actual
    network call, anisette headers, and getAuth - so fetch_reports_with_cache
    and _raise_for_status_marking_stale run for real instead of being
    mocked away, exercising do_POST's per-request stale tracking honestly."""
    monkeypatch.setattr(mh_endpoint, "getAuth", lambda **kwargs: ("dsid", "token"))
    monkeypatch.setattr(mh_endpoint.pypush_gsa_icloud, "generate_anisette_headers", lambda: {})

    def _use(response):
        monkeypatch.setattr(mh_endpoint.requests, "post", lambda *a, **k: response)

    return _use


def test_post_fetch_reports_apple_session_stale_true_after_a_401_with_no_cache(
    server, mock_apple_transport,
):
    mh_endpoint.history_store = HistoryStore(":memory:")
    mock_apple_transport(_mock_apple_response(401))

    status, body = _post(server, '/', {"ids": ["hash-a"], "days": 7})

    # No cache existed yet for this id, so fetch_reports_with_cache falls
    # back to an empty (but still 200) result rather than raising - see
    # its own docstring/tests in test_history_archiver.py.
    assert status == 200
    assert body["results"] == []
    assert body["appleSessionStale"] is True


def test_post_fetch_reports_apple_session_stale_false_after_a_successful_live_call(
    server, mock_apple_transport,
):
    mh_endpoint.history_store = HistoryStore(":memory:")
    mock_apple_transport(_mock_apple_response(200, {"results": []}))

    status, body = _post(server, '/', {"ids": ["hash-a"], "days": 7})

    assert status == 200
    assert body["appleSessionStale"] is False


def test_post_fetch_reports_apple_session_stale_true_on_a_cache_hit_with_no_auth_json(server):
    # The id is fresh, so fetch_reports_with_cache never calls
    # fetch_from_apple at all - this request has no live opinion of its
    # own, so it falls back to whether the session needs a login, and no
    # auth.json exists (the fixture points getConfigFile at an empty
    # tmp_path with nothing configured in config.ini either).
    store = HistoryStore(":memory:")
    store.mark_polled("hash-a", when=int(time.time()))
    mh_endpoint.history_store = store

    status, body = _post(server, '/', {"ids": ["hash-a"], "days": 7, "force": False})

    assert status == 200
    assert body["appleSessionStale"] is True


def test_post_fetch_returns_503_when_a_401_propagates_with_no_store_to_fall_back_on(
    server, mock_apple_transport,
):
    mh_endpoint.history_store = None
    mock_apple_transport(_mock_apple_response(401))

    status, body = _post(server, '/', {"ids": ["hash-a"], "days": 7})

    assert status == 503
    assert body == {"error": "apple_session_expired"}


def test_post_fetch_does_not_return_503_for_a_non_auth_exception_while_stale(server, monkeypatch):
    mh_endpoint.apple_session_stale = True
    monkeypatch.setattr(
        mh_endpoint.history_archiver, "fetch_reports_with_cache",
        lambda *a, **k: (_ for _ in ()).throw(ConnectionError("network down")),
    )

    # The untouched non-auth-failure branch has a pre-existing, out of
    # scope quirk (send_response with no end_headers/body -> the
    # connection just closes) - what matters here is only that it is
    # provably *not* the 503 apple_session_expired path.
    with pytest.raises(RemoteDisconnected):
        _post(server, '/', {"ids": ["hash-a"], "days": 7})


def test_is_apple_auth_exception_true_for_401_http_error():
    response = MagicMock(status_code=401)
    assert mh_endpoint._is_apple_auth_exception(requests.exceptions.HTTPError(response=response)) is True


def test_is_apple_auth_exception_true_for_403_http_error():
    response = MagicMock(status_code=403)
    assert mh_endpoint._is_apple_auth_exception(requests.exceptions.HTTPError(response=response)) is True


def test_is_apple_auth_exception_false_for_500_http_error():
    response = MagicMock(status_code=500)
    assert mh_endpoint._is_apple_auth_exception(requests.exceptions.HTTPError(response=response)) is False


def test_is_apple_auth_exception_true_for_no_apple_session_runtime_error():
    error = RuntimeError(
        "No Apple session available and no appleid/appleid_pass configured in "
        "config.ini - log in again via the app's in-app Apple ID login.")
    assert mh_endpoint._is_apple_auth_exception(error) is True


def test_is_apple_auth_exception_false_for_an_unrelated_runtime_error():
    assert mh_endpoint._is_apple_auth_exception(RuntimeError("disk is full")) is False


def test_is_apple_auth_exception_false_for_a_generic_exception():
    assert mh_endpoint._is_apple_auth_exception(Exception("boom")) is False
