import base64
from unittest.mock import MagicMock, patch

import pytest
import requests

from register import pypush_gsa_icloud as gsa


def test_dispatch_second_factor_trusted_device_calls_trusted_device_flow():
    with patch.object(gsa, "trusted_device_second_factor") as trusted_device, \
            patch.object(gsa, "sms_second_factor") as sms:
        gsa._dispatch_second_factor("trustedDeviceSecondaryAuth", "dsid-1", "token-1")

    trusted_device.assert_called_once_with("dsid-1", "token-1")
    sms.assert_not_called()


def test_dispatch_second_factor_sms_calls_sms_flow():
    with patch.object(gsa, "trusted_device_second_factor") as trusted_device, \
            patch.object(gsa, "sms_second_factor") as sms:
        gsa._dispatch_second_factor("secondaryAuth", "dsid-1", "token-1")

    sms.assert_called_once_with("dsid-1", "token-1")
    trusted_device.assert_not_called()


def test_dispatch_second_factor_unknown_au_raises():
    with pytest.raises(ValueError):
        gsa._dispatch_second_factor("somethingElse", "dsid-1", "token-1")


def test_common_2fa_headers_includes_identity_token_and_anisette_data():
    with patch.object(gsa, "generate_anisette_headers", return_value={"X-Anisette": "1"}):
        headers = gsa._common_2fa_headers("dsid-1", "token-1")

    assert headers["X-Apple-Identity-Token"] == base64.b64encode(b"dsid-1:token-1").decode()
    assert headers["User-Agent"] == "Xcode"
    assert headers["X-Anisette"] == "1"


def _mock_response(headers=None, ok=True, status_code=200, text=""):
    resp = MagicMock()
    resp.ok = ok
    resp.status_code = status_code
    resp.headers = headers or {}
    resp.text = text
    resp.raise_for_status = MagicMock()
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    return resp


def test_trusted_device_second_factor_triggers_then_submits_code():
    trigger_resp = _mock_response()
    submit_resp = _mock_response()

    with patch.object(gsa, "generate_anisette_headers", return_value={}) as mock_anisette, \
            patch("builtins.input", return_value="654321"), \
            patch.object(gsa.requests, "get", side_effect=[trigger_resp, submit_resp]) as mock_get:
        gsa.trusted_device_second_factor("dsid-1", "token-1")

    trigger_call, submit_call = mock_get.call_args_list
    assert trigger_call.args[0] == "https://gsa.apple.com/auth/verify/trusteddevice"
    assert trigger_call.kwargs["timeout"] == 10
    assert submit_call.args[0] == "https://gsa.apple.com/grandslam/GsService2/validate"
    assert submit_call.kwargs["timeout"] == 10
    assert submit_call.kwargs["headers"]["security-code"] == "654321"
    # Once building the base headers, once more right before submitting the code.
    assert mock_anisette.call_count == 2


def test_trusted_device_second_factor_ignores_non_server_error_on_trigger():
    trigger_resp = _mock_response(status_code=409, ok=False)
    submit_resp = _mock_response()

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch("builtins.input", return_value="123456"), \
            patch.object(gsa.requests, "get", side_effect=[trigger_resp, submit_resp]):
        gsa.trusted_device_second_factor("dsid-1", "token-1")

    trigger_resp.raise_for_status.assert_not_called()


def test_trusted_device_second_factor_raises_on_trigger_server_error():
    trigger_resp = _mock_response(status_code=500, ok=False)
    trigger_resp.raise_for_status.side_effect = requests.HTTPError("500 Server Error")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=trigger_resp):
        with pytest.raises(requests.HTTPError):
            gsa.trusted_device_second_factor("dsid-1", "token-1")


def test_trusted_device_second_factor_propagates_submit_http_error():
    trigger_resp = _mock_response()
    submit_resp = _mock_response(status_code=400, ok=False)
    submit_resp.raise_for_status.side_effect = requests.HTTPError("400 Client Error")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch("builtins.input", return_value="000000"), \
            patch.object(gsa.requests, "get", side_effect=[trigger_resp, submit_resp]):
        with pytest.raises(requests.HTTPError):
            gsa.trusted_device_second_factor("dsid-1", "token-1")


def test_trusted_device_second_factor_resends_when_code_not_entered_in_time():
    trigger_resp = _mock_response()
    resend_trigger_resp = _mock_response()
    submit_resp = _mock_response()

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch("builtins.input", side_effect=["", "", "123456"]), \
            patch.object(gsa.time, "sleep") as mock_sleep, \
            patch.object(gsa.time, "perf_counter", side_effect=[0, 0]), \
            patch.object(gsa.requests, "get", side_effect=[trigger_resp, resend_trigger_resp, submit_resp]) as mock_get:
        gsa.trusted_device_second_factor("dsid-1", "token-1")

    mock_sleep.assert_called_once_with(gsa.WAITING_TIME)
    trigger_urls = [call.args[0] for call in mock_get.call_args_list]
    assert trigger_urls == [
        "https://gsa.apple.com/auth/verify/trusteddevice",
        "https://gsa.apple.com/auth/verify/trusteddevice",
        "https://gsa.apple.com/grandslam/GsService2/validate",
    ]
