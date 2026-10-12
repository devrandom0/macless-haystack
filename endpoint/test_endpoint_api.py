import pytest
from unittest.mock import MagicMock, patch
import json
import io
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))
from mh_endpoint import ServerHandler

def test_endpoint_api_status():
    handler = ServerHandler.__new__(ServerHandler)
    handler.headers = {}
    handler.path = "/api/status"
    handler.command = "GET"
    handler.wfile = io.BytesIO()
    
    with patch.object(handler, "authenticate", return_value=True):
        with patch.object(handler, "send_response") as mock_resp, \
             patch.object(handler, "send_header"), \
             patch.object(handler, "end_headers"):
            handler.do_GET()
            mock_resp.assert_called_with(200)
            data = json.loads(handler.wfile.getvalue().decode())
            assert "findmy" in data

def test_endpoint_api_devices():
    handler = ServerHandler.__new__(ServerHandler)
    handler.headers = {}
    handler.path = "/api/devices"
    handler.command = "GET"
    handler.wfile = io.BytesIO()
    
    with patch.object(handler, "authenticate", return_value=True):
        with patch.object(handler, "send_response") as mock_resp, \
             patch.object(handler, "send_header"), \
             patch.object(handler, "end_headers"):
            handler.do_GET()
            mock_resp.assert_called_with(200)
            data = json.loads(handler.wfile.getvalue().decode())
            assert "devices" in data

def test_endpoint_api_auth_login():
    handler = ServerHandler.__new__(ServerHandler)
    body = json.dumps({"username": "test@apple.com", "password": "pw"}).encode()
    handler.headers = {"content-length": str(len(body))}
    handler.rfile = io.BytesIO(body)
    handler.path = "/api/auth/login"
    handler.command = "POST"
    handler.wfile = io.BytesIO()

    with patch.object(handler, "authenticate", return_value=True):
        with patch("mh_endpoint.findmy_service.login", return_value={"logged_in": False, "state": "REQUIRE_2FA"}):
            with patch.object(handler, "send_response") as mock_resp, \
                 patch.object(handler, "send_header"), \
                 patch.object(handler, "end_headers"):
                handler.do_POST()
                mock_resp.assert_called_with(200)
                data = json.loads(handler.wfile.getvalue().decode())
                assert data["state"] == "REQUIRE_2FA"

def test_endpoint_api_reports():
    handler = ServerHandler.__new__(ServerHandler)
    body = json.dumps({"private_key": "some_key"}).encode()
    handler.headers = {"content-length": str(len(body))}
    handler.rfile = io.BytesIO(body)
    handler.path = "/api/reports"
    handler.command = "POST"
    handler.wfile = io.BytesIO()

    with patch.object(handler, "authenticate", return_value=True):
        with patch("mh_endpoint.findmy_service.fetch_reports_for_key", return_value=[{"lat": 1.0, "lon": 2.0}]):
            with patch.object(handler, "send_response") as mock_resp, \
                 patch.object(handler, "send_header"), \
                 patch.object(handler, "end_headers"):
                handler.do_POST()
                mock_resp.assert_called_with(200)
                data = json.loads(handler.wfile.getvalue().decode())
                assert len(data["reports"]) == 1
                assert data["reports"][0]["lat"] == 1.0
