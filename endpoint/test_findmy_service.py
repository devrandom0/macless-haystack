import pytest
from unittest.mock import MagicMock, patch
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))
from findmy_service import FindMyService

def test_findmy_service_initial_state():
    service = FindMyService(anisette_url="http://anisette:6969", storage_path="/tmp/test_auth.json")
    assert service.get_status()["logged_in"] is False

def test_findmy_service_login_requires_2fa():
    service = FindMyService(anisette_url="http://anisette:6969", storage_path="/tmp/test_auth.json")
    mock_acc = MagicMock()
    mock_state = MagicMock()
    mock_state.name = "REQUIRE_2FA"
    mock_acc.login.return_value = mock_state
    
    with patch("findmy_service.AppleAccount", return_value=mock_acc):
        res = service.login("user@example.com", "secret")
        assert res["state"] == "REQUIRE_2FA"
        assert res["logged_in"] is False

def test_findmy_service_format_report():
    service = FindMyService(anisette_url="http://anisette:6969", storage_path="/tmp/test_auth.json")
    mock_report = MagicMock()
    mock_report.latitude = 37.7749
    mock_report.longitude = -122.4194
    mock_report.horizontal_accuracy = 10
    mock_report.confidence = 3
    mock_report.status = 1
    mock_report.timestamp.isoformat.return_value = "2026-10-12T12:00:00Z"
    
    formatted = service.format_report(mock_report)
    assert formatted["lat"] == 37.7749
    assert formatted["lon"] == -122.4194
    assert formatted["timestamp"] == "2026-10-12T12:00:00Z"
