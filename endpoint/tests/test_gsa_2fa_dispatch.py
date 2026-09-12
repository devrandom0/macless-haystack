import base64
import logging
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


def test_request_trusted_device_code_returns_headers_for_submission():
    trigger_resp = _mock_response()

    with patch.object(gsa, "generate_anisette_headers", return_value={"X-Anisette": "1"}), \
            patch.object(gsa.requests, "get", return_value=trigger_resp) as mock_get:
        headers = gsa.request_trusted_device_code("dsid-1", "token-1")

    mock_get.assert_called_once()
    assert mock_get.call_args.args[0] == "https://gsa.apple.com/auth/verify/trusteddevice"
    assert headers["Content-Type"] == "text/x-xml-plist"
    assert headers["X-Anisette"] == "1"


def test_submit_trusted_device_code_posts_security_code():
    submit_resp = _mock_response()

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=submit_resp) as mock_get:
        gsa.submit_trusted_device_code({"X-Apple-Identity-Token": "id-1"}, "654321")

    mock_get.assert_called_once()
    assert mock_get.call_args.args[0] == "https://gsa.apple.com/grandslam/GsService2/validate"
    assert mock_get.call_args.kwargs["headers"]["security-code"] == "654321"


def test_submit_trusted_device_code_raises_on_server_error():
    submit_resp = _mock_response(status_code=500, ok=False)
    submit_resp.raise_for_status.side_effect = requests.HTTPError("500 Server Error")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=submit_resp):
        with pytest.raises(requests.HTTPError):
            gsa.submit_trusted_device_code({}, "000000")


def test_submit_trusted_device_code_does_not_log_response_body(caplog):
    secret_marker = "secret-validate-response-body-should-never-be-logged"
    submit_resp = _mock_response(text=secret_marker)

    with caplog.at_level(logging.DEBUG), \
            patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=submit_resp):
        gsa.submit_trusted_device_code({}, "654321")

    assert secret_marker not in caplog.text


def test_request_code_does_not_log_headers(caplog):
    secret_token = "secret-identity-token-should-never-be-logged"
    put_resp = _mock_response()

    with caplog.at_level(logging.DEBUG), \
            patch.object(gsa.requests, "put", return_value=put_resp), \
            patch("builtins.input", return_value="123456"):
        gsa.request_code({"X-Apple-Identity-Token": secret_token}, 7)

    assert secret_token not in caplog.text


def test_request_sms_code_extracts_phone_id_from_boot_args():
    boot_args = '{"direct": {"phoneNumberVerification": {"trustedPhoneNumber": {"id": 7}}}}'
    auth_resp = _mock_response(
        text=f'<script class="boot_args">{boot_args}</script>',
    )

    with patch.object(gsa, "generate_anisette_headers", return_value={"X-Anisette": "1"}), \
            patch.object(gsa.requests, "get", return_value=auth_resp) as mock_get:
        headers, sms_id = gsa.request_sms_code("dsid-1", "token-1")

    mock_get.assert_called_once_with("https://gsa.apple.com/auth", headers=headers, verify=False)
    assert sms_id == 7
    assert headers["X-Anisette"] == "1"


def test_request_sms_code_defaults_to_phone_id_one_when_boot_args_missing():
    auth_resp = _mock_response(text="<html>no script here</html>")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=auth_resp):
        _, sms_id = gsa.request_sms_code("dsid-1", "token-1")

    assert sms_id == 1


def test_submit_sms_code_succeeds_when_dsid_header_present():
    submit_resp = _mock_response(headers={"X-Apple-DSID": "dsid-1"}, ok=True)

    with patch.object(gsa, "generate_anisette_headers", return_value={"X-Anisette": "1"}), \
            patch.object(gsa.requests, "post", return_value=submit_resp) as mock_post:
        gsa.submit_sms_code({"h": "1"}, 7, "654321")

    assert mock_post.call_args.args[0] == "https://gsa.apple.com/auth/verify/phone/securitycode"
    assert mock_post.call_args.kwargs["json"] == {
        "phoneNumber": {"id": 7}, "mode": "sms", "securityCode": {"code": "654321"},
    }
    assert mock_post.call_args.kwargs["headers"]["X-Anisette"] == "1"


def test_submit_sms_code_raises_apple_auth_error_when_dsid_header_missing():
    submit_resp = _mock_response(headers={}, ok=True)

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=submit_resp):
        with pytest.raises(gsa.AppleAuthError, match="invalid_code"):
            gsa.submit_sms_code({}, 7, "000000")


def test_request_second_factor_code_dispatches_trusted_device():
    with patch.object(gsa, "request_trusted_device_code", return_value={"h": "1"}) as mock_req:
        state = gsa.request_second_factor_code("trustedDeviceSecondaryAuth", "d-1", "t-1")

    mock_req.assert_called_once_with("d-1", "t-1")
    assert state == {"headers": {"h": "1"}}


def test_request_second_factor_code_dispatches_sms():
    with patch.object(gsa, "request_sms_code", return_value=({"h": "1"}, 7)) as mock_req:
        state = gsa.request_second_factor_code("secondaryAuth", "d-1", "t-1")

    mock_req.assert_called_once_with("d-1", "t-1")
    assert state == {"headers": {"h": "1"}, "sms_id": 7}


def test_request_second_factor_code_raises_for_unknown_method():
    with pytest.raises(gsa.AppleAuthError):
        gsa.request_second_factor_code("somethingElse", "d-1", "t-1")


def test_submit_second_factor_code_dispatches_trusted_device():
    with patch.object(gsa, "submit_trusted_device_code") as mock_submit:
        gsa.submit_second_factor_code("trustedDeviceSecondaryAuth", {"headers": {"h": "1"}}, "654321")

    mock_submit.assert_called_once_with({"h": "1"}, "654321")


def test_submit_second_factor_code_dispatches_sms():
    with patch.object(gsa, "submit_sms_code") as mock_submit:
        gsa.submit_second_factor_code("secondaryAuth", {"headers": {"h": "1"}, "sms_id": 7}, "654321")

    mock_submit.assert_called_once_with({"h": "1"}, 7, "654321")


def test_submit_second_factor_code_raises_for_unknown_method():
    with pytest.raises(gsa.AppleAuthError):
        gsa.submit_second_factor_code("somethingElse", {}, "654321")
