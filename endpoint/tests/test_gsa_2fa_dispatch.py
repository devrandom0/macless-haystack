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


def test_submit_trusted_device_code_does_not_log_header_values(caplog):
    secret_cookie = "secret-session-cookie-value-should-never-be-logged"
    submit_resp = _mock_response(headers={"Set-Cookie": f"aasp={secret_cookie}"})

    with caplog.at_level(logging.DEBUG), \
            patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=submit_resp):
        gsa.submit_trusted_device_code({}, "654321")

    assert secret_cookie not in caplog.text
    assert "Set-Cookie" in caplog.text


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

    mock_get.assert_called_once_with(
        "https://gsa.apple.com/auth", headers=headers, verify=False, timeout=10)
    assert sms_id == 7
    assert headers["X-Anisette"] == "1"


def test_request_sms_code_uses_first_number_from_two_sv_shape():
    boot_args = (
        '{"direct": {"twoSV": {"phoneNumberVerification": '
        '{"trustedPhoneNumbers": [{"id": 9}, {"id": 10}]}}}}'
    )
    auth_resp = _mock_response(text=f'<script class="boot_args">{boot_args}</script>')

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=auth_resp):
        _, sms_id = gsa.request_sms_code("dsid-1", "token-1")

    assert sms_id == 9


def test_request_sms_code_falls_back_to_id_one_when_boot_args_unparseable():
    auth_resp = _mock_response(text='<script class="boot_args">{not json</script>')

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=auth_resp):
        _, sms_id = gsa.request_sms_code("dsid-1", "token-1")

    assert sms_id == 1


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


def test_submit_sms_code_raises_apple_auth_error_not_http_error_on_400(caplog):
    # A wrong code gets a plain 400/401 back from Apple, not a 200 with a
    # missing X-Apple-DSID header - that must map to AppleAuthError so the
    # caller reports invalid_code, not apple_unreachable via a RequestException.
    submit_resp = _mock_response(status_code=400, ok=False, headers={})
    submit_resp.raise_for_status.side_effect = requests.HTTPError("400 Client Error")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=submit_resp):
        with pytest.raises(gsa.AppleAuthError, match="invalid_code"):
            gsa.submit_sms_code({}, 7, "000000")

    submit_resp.raise_for_status.assert_not_called()


def test_submit_sms_code_raises_apple_auth_error_not_http_error_on_401(caplog):
    submit_resp = _mock_response(status_code=401, ok=False, headers={})
    submit_resp.raise_for_status.side_effect = requests.HTTPError("401 Client Error")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=submit_resp):
        with pytest.raises(gsa.AppleAuthError, match="invalid_code"):
            gsa.submit_sms_code({}, 7, "000000")


def test_submit_sms_code_raises_http_error_on_server_error():
    submit_resp = _mock_response(status_code=500, ok=False, headers={})
    submit_resp.raise_for_status.side_effect = requests.HTTPError("500 Server Error")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=submit_resp):
        with pytest.raises(requests.HTTPError):
            gsa.submit_sms_code({}, 7, "000000")


def test_submit_sms_code_does_not_log_header_values(caplog):
    secret_cookie = "secret-session-cookie-value-should-never-be-logged"
    submit_resp = _mock_response(headers={"X-Apple-DSID": "dsid-1", "Set-Cookie": f"scnt={secret_cookie}"})

    with caplog.at_level(logging.DEBUG), \
            patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=submit_resp):
        gsa.submit_sms_code({}, 7, "654321")

    assert secret_cookie not in caplog.text
    assert "Set-Cookie" in caplog.text


def test_request_sms_code_does_not_log_boot_args_or_page_content_on_missing_key(caplog):
    secret_marker = "secret-phone-number-payload-should-never-be-logged"
    boot_args = f'{{"direct": {{"unexpected": "{secret_marker}"}}}}'
    auth_resp = _mock_response(text=f'<script class="boot_args">{boot_args}</script>')

    with caplog.at_level(logging.DEBUG), \
            patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=auth_resp):
        gsa.request_sms_code("dsid-1", "token-1")

    assert secret_marker not in caplog.text


def test_request_sms_code_does_not_log_page_content_when_script_missing(caplog):
    secret_marker = "secret-page-content-should-never-be-logged"
    auth_resp = _mock_response(text=f"<html>{secret_marker}</html>")

    with caplog.at_level(logging.DEBUG), \
            patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=auth_resp):
        gsa.request_sms_code("dsid-1", "token-1")

    assert secret_marker not in caplog.text


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

    mock_submit.assert_called_once_with({"h": "1"}, 7, "654321", "sms")


def test_submit_second_factor_code_dispatches_voice_when_state_carries_that_mode():
    with patch.object(gsa, "submit_sms_code") as mock_submit:
        gsa.submit_second_factor_code(
            "secondaryAuth", {"headers": {"h": "1"}, "sms_id": 7, "mode": "voice"}, "654321")

    mock_submit.assert_called_once_with({"h": "1"}, 7, "654321", "voice")


def test_submit_second_factor_code_raises_for_unknown_method():
    with pytest.raises(gsa.AppleAuthError):
        gsa.submit_second_factor_code("somethingElse", {}, "654321")


def test_submit_sms_code_sends_voice_mode_when_requested():
    submit_resp = _mock_response(headers={"X-Apple-DSID": "dsid-1"}, ok=True)

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=submit_resp) as mock_post:
        gsa.submit_sms_code({}, 7, "654321", "voice")

    assert mock_post.call_args.kwargs["json"] == {
        "phoneNumber": {"id": 7}, "mode": "voice", "securityCode": {"code": "654321"},
    }


def test_extract_trusted_phone_numbers_from_classic_shape():
    boot_args = {
        "direct": {
            "phoneNumberVerification": {
                "trustedPhoneNumber": {"id": 1, "numberWithDialCode": "+1 •••• •••1234"},
            },
        },
    }

    numbers = gsa._extract_trusted_phone_numbers(boot_args)

    assert numbers == [{"id": 1, "number": "+1 •••• •••1234"}]


def test_extract_trusted_phone_numbers_from_two_sv_shape():
    boot_args = {
        "direct": {
            "twoSV": {
                "phoneNumberVerification": {
                    "trustedPhoneNumbers": [
                        {"id": 2, "numberWithDialCode": "+1 •••• •••5678"},
                        {"id": 3, "numberWithDialCode": "+1 •••• •••9012"},
                    ],
                },
            },
        },
    }

    numbers = gsa._extract_trusted_phone_numbers(boot_args)

    assert numbers == [
        {"id": 2, "number": "+1 •••• •••5678"},
        {"id": 3, "number": "+1 •••• •••9012"},
    ]


def test_extract_trusted_phone_numbers_merges_both_shapes_without_duplicates():
    boot_args = {
        "direct": {
            "phoneNumberVerification": {
                "trustedPhoneNumber": {"id": 1, "numberWithDialCode": "+1 •••• •••1234"},
            },
            "twoSV": {
                "phoneNumberVerification": {
                    "trustedPhoneNumbers": [
                        {"id": 1, "numberWithDialCode": "+1 •••• •••1234"},
                        {"id": 2, "numberWithDialCode": "+1 •••• •••5678"},
                    ],
                },
            },
        },
    }

    numbers = gsa._extract_trusted_phone_numbers(boot_args)

    assert numbers == [
        {"id": 1, "number": "+1 •••• •••1234"},
        {"id": 2, "number": "+1 •••• •••5678"},
    ]


def test_extract_trusted_phone_numbers_returns_empty_list_when_absent():
    assert gsa._extract_trusted_phone_numbers({"direct": {}}) == []


def test_extract_trusted_phone_numbers_ignores_entries_missing_id():
    boot_args = {"direct": {"phoneNumberVerification": {"trustedPhoneNumber": {"numberWithDialCode": "x"}}}}

    assert gsa._extract_trusted_phone_numbers(boot_args) == []


def test_extract_trusted_phone_numbers_accepts_obfuscated_number_field():
    boot_args = {
        "direct": {
            "phoneNumberVerification": {
                "trustedPhoneNumber": {"id": 1, "obfuscatedNumber": "(•••) •••-••34"},
            },
        },
    }

    assert gsa._extract_trusted_phone_numbers(boot_args) == [{"id": 1, "number": "(•••) •••-••34"}]


def test_extract_trusted_phone_numbers_accepts_last_two_digits_field():
    boot_args = {
        "direct": {
            "phoneNumberVerification": {
                "trustedPhoneNumber": {"id": 1, "lastTwoDigits": "34"},
            },
        },
    }

    assert gsa._extract_trusted_phone_numbers(boot_args) == [{"id": 1, "number": "34"}]


def test_extract_trusted_phone_numbers_never_falls_back_to_unmasked_number_field():
    # "number" (unlike numberWithDialCode/obfuscatedNumber/lastTwoDigits) is
    # not documented as masked - never surface it, even as a last resort.
    boot_args = {
        "direct": {
            "phoneNumberVerification": {
                "trustedPhoneNumber": {"id": 1, "number": "+15551234567"},
            },
        },
    }

    assert gsa._extract_trusted_phone_numbers(boot_args) == [{"id": 1, "number": None}]


def test_extract_trusted_phone_numbers_ignores_non_string_masked_fields():
    boot_args = {
        "direct": {
            "phoneNumberVerification": {
                "trustedPhoneNumber": {"id": 1, "numberWithDialCode": 5551234},
            },
        },
    }

    assert gsa._extract_trusted_phone_numbers(boot_args) == [{"id": 1, "number": None}]


def test_list_trusted_phone_numbers_parses_boot_args():
    boot_args = (
        '{"direct": {"phoneNumberVerification": '
        '{"trustedPhoneNumber": {"id": 7, "numberWithDialCode": "+1 •••• •••1234"}}}}'
    )
    auth_resp = _mock_response(text=f'<script class="boot_args">{boot_args}</script>')

    with patch.object(gsa, "generate_anisette_headers", return_value={"X-Anisette": "1"}), \
            patch.object(gsa.requests, "get", return_value=auth_resp) as mock_get:
        headers, numbers = gsa.list_trusted_phone_numbers("dsid-1", "token-1")

    mock_get.assert_called_once_with(
        "https://gsa.apple.com/auth", headers=headers, verify=False, timeout=10)
    assert numbers == [{"id": 7, "number": "+1 •••• •••1234"}]
    assert headers["X-Anisette"] == "1"


def test_list_trusted_phone_numbers_returns_none_when_boot_args_missing():
    # None (as opposed to []) means the auth page itself couldn't be parsed -
    # the caller needs to tell that apart from a well-formed page reporting
    # zero trusted phone numbers.
    auth_resp = _mock_response(text="<html>no script here</html>")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=auth_resp):
        _, numbers = gsa.list_trusted_phone_numbers("dsid-1", "token-1")

    assert numbers is None


def test_list_trusted_phone_numbers_returns_none_on_malformed_json():
    auth_resp = _mock_response(text='<script class="boot_args">{not json</script>')

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=auth_resp):
        _, numbers = gsa.list_trusted_phone_numbers("dsid-1", "token-1")

    assert numbers is None


def test_list_trusted_phone_numbers_returns_empty_list_when_boot_args_has_no_phone_numbers():
    boot_args = '{"direct": {"unexpected": "x"}}'
    auth_resp = _mock_response(text=f'<script class="boot_args">{boot_args}</script>')

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=auth_resp):
        _, numbers = gsa.list_trusted_phone_numbers("dsid-1", "token-1")

    assert numbers == []


def test_list_trusted_phone_numbers_does_not_log_boot_args_or_page_content(caplog):
    secret_marker = "secret-phone-number-payload-should-never-be-logged"
    boot_args = f'{{"direct": {{"unexpected": "{secret_marker}"}}}}'
    auth_resp = _mock_response(text=f'<script class="boot_args">{boot_args}</script>')

    with caplog.at_level(logging.DEBUG), \
            patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "get", return_value=auth_resp):
        gsa.list_trusted_phone_numbers("dsid-1", "token-1")

    assert secret_marker not in caplog.text


def test_trigger_phone_second_factor_sends_sms_mode():
    trigger_resp = _mock_response()

    with patch.object(gsa, "generate_anisette_headers", return_value={"X-Anisette": "1"}), \
            patch.object(gsa.requests, "put", return_value=trigger_resp) as mock_put:
        gsa.trigger_phone_second_factor({"h": "1"}, 7, "sms")

    assert mock_put.call_args.args[0] == "https://gsa.apple.com/auth/verify/phone/"
    assert mock_put.call_args.kwargs["json"] == {"phoneNumber": {"id": 7}, "mode": "sms"}
    assert mock_put.call_args.kwargs["headers"]["X-Anisette"] == "1"


def test_trigger_phone_second_factor_sends_voice_mode():
    trigger_resp = _mock_response()

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "put", return_value=trigger_resp) as mock_put:
        gsa.trigger_phone_second_factor({}, 7, "voice")

    assert mock_put.call_args.kwargs["json"] == {"phoneNumber": {"id": 7}, "mode": "voice"}


def test_trigger_phone_second_factor_rejects_unknown_mode():
    with pytest.raises(AssertionError):
        gsa.trigger_phone_second_factor({}, 7, "carrier_pigeon")


def test_trigger_phone_second_factor_raises_http_error_on_server_error():
    trigger_resp = _mock_response(status_code=500, ok=False)
    trigger_resp.raise_for_status.side_effect = requests.HTTPError("500 Server Error")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "put", return_value=trigger_resp):
        with pytest.raises(requests.HTTPError):
            gsa.trigger_phone_second_factor({}, 7, "sms")


def test_trigger_phone_second_factor_raises_apple_phone_trigger_rejected_on_client_error():
    # Apple answers a rate-limited/precondition-failed trigger with a plain
    # 4xx (412/423/429 have all been observed) - that's Apple actively
    # refusing to send a code, not a network/transport failure, so it must
    # not surface as the generic apple_unreachable a RequestException maps to.
    trigger_resp = _mock_response(status_code=429, ok=False)
    trigger_resp.raise_for_status.side_effect = requests.HTTPError("429 Client Error")

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "put", return_value=trigger_resp):
        with pytest.raises(gsa.ApplePhoneTriggerRejected) as exc_info:
            gsa.trigger_phone_second_factor({}, 7, "sms")

    assert exc_info.value.status_code == 429
    trigger_resp.raise_for_status.assert_not_called()
