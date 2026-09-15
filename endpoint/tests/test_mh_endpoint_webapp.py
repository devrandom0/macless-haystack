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


def test_returns_500_for_a_malformed_path(server, no_auth, web_root):
    response, _ = _get(server, '/webapp/%00')
    assert response.status == 500


def test_webapp_requires_authentication_when_configured(server, web_root, monkeypatch):
    monkeypatch.setattr(mh_config, "getEndpointUser", lambda: "simo")
    monkeypatch.setattr(mh_config, "getEndpointPass", lambda: "hunter2")
    monkeypatch.setattr(mh_config, "getBasicAuthUsers", lambda: {})

    response, _ = _get(server, '/webapp/')
    assert response.status == 401
