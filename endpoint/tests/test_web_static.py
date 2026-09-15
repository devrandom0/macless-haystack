from pathlib import Path

import pytest

from web_static import resolve_static_path, guess_content_type


@pytest.fixture
def web_root(tmp_path):
    root = tmp_path / "web_root"
    root.mkdir()
    (root / "index.html").write_text("<html>home</html>")
    (root / "main.dart.js").write_text("// js")
    sub = root / "assets"
    sub.mkdir()
    (sub / "AssetManifest.json").write_text("{}")
    return root


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
    (web_root.parent / "secret.txt").write_text("should not be reachable")
    result = resolve_static_path("/webapp/../secret.txt", web_root)
    assert result is None


def test_rejects_url_encoded_traversal(web_root):
    (web_root.parent / "secret.txt").write_text("should not be reachable")
    result = resolve_static_path("/webapp/%2e%2e/secret.txt", web_root)
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
    assert guess_content_type(Path("mystery.unknownext")) == "application/octet-stream"
