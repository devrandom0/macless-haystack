from unittest.mock import MagicMock, patch

import pytest

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


def _mock_response(headers=None, ok=True):
    resp = MagicMock()
    resp.ok = ok
    resp.headers = headers or {}
    resp.raise_for_status = MagicMock()
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    return resp


def test_trusted_device_second_factor_triggers_then_submits_code_and_succeeds():
    trigger_resp = _mock_response()
    submit_resp = _mock_response(headers={"X-Apple-DSID": "123"})

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch("builtins.input", return_value="654321"), \
            patch.object(gsa.requests, "get", side_effect=[trigger_resp, submit_resp]) as mock_get:
        gsa.trusted_device_second_factor("dsid-1", "token-1")

    trigger_call, submit_call = mock_get.call_args_list
    assert trigger_call.args[0] == "https://gsa.apple.com/auth/verify/trusteddevice"
    assert submit_call.args[0] == "https://gsa.apple.com/grandslam/GsService2/validate"
    assert submit_call.kwargs["headers"]["security-code"] == "654321"


def test_trusted_device_second_factor_raises_when_no_dsid_header():
    trigger_resp = _mock_response()
    submit_resp = _mock_response(headers={})

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch("builtins.input", return_value="000000"), \
            patch.object(gsa.requests, "get", side_effect=[trigger_resp, submit_resp]):
        with pytest.raises(Exception, match="2FA unsuccessful"):
            gsa.trusted_device_second_factor("dsid-1", "token-1")
