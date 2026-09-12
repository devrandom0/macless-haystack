import logging
from unittest.mock import MagicMock, patch

import pytest

from register import pypush_gsa_icloud as gsa


def _srp_user_mock(session_key_matches=True, challenge_ok=True):
    usr = MagicMock()
    usr.process_challenge.return_value = b"m1" if challenge_ok else None
    usr.authenticated.return_value = session_key_matches
    return usr


def test_gsa_authenticate_returns_spd_when_no_second_factor_required():
    init_resp = {"sp": "s2k", "s": b"salt", "i": 1024, "B": b"B", "c": "c-token"}
    complete_resp = {"M2": b"m2", "spd": b"encrypted-spd"}

    with patch.object(gsa.srp, "User") as mock_user_cls, \
            patch.object(gsa, "gsa_authenticated_request", side_effect=[init_resp, complete_resp]), \
            patch.object(gsa, "decrypt_cbc", return_value=b"decrypted"), \
            patch.object(gsa.plist, "loads", return_value={"adsid": "adsid-1"}):
        mock_user = _srp_user_mock()
        mock_user.start_authentication.return_value = (None, "a-value")
        mock_user_cls.return_value = mock_user

        result = gsa.gsa_authenticate("user@example.com", "hunter2")

    assert result == {"adsid": "adsid-1"}


def test_gsa_authenticate_returns_needs_second_factor_for_trusted_device():
    init_resp = {"sp": "s2k", "s": b"salt", "i": 1024, "B": b"B", "c": "c-token"}
    complete_resp = {
        "M2": b"m2", "spd": b"encrypted-spd",
        "Status": {"au": "trustedDeviceSecondaryAuth"},
    }

    with patch.object(gsa.srp, "User") as mock_user_cls, \
            patch.object(gsa, "gsa_authenticated_request", side_effect=[init_resp, complete_resp]), \
            patch.object(gsa, "decrypt_cbc", return_value=b"decrypted"), \
            patch.object(gsa.plist, "loads", return_value={"adsid": "adsid-1", "GsIdmsToken": "token-1"}):
        mock_user = _srp_user_mock()
        mock_user.start_authentication.return_value = (None, "a-value")
        mock_user_cls.return_value = mock_user

        result = gsa.gsa_authenticate("user@example.com", "hunter2")

    assert result == gsa.NeedsSecondFactor(
        method="trustedDeviceSecondaryAuth", dsid="adsid-1", idms_token="token-1",
    )


def test_gsa_authenticate_raises_on_failed_challenge():
    init_resp = {"sp": "s2k", "s": b"salt", "i": 1024, "B": b"B", "c": "c-token"}

    with patch.object(gsa.srp, "User") as mock_user_cls, \
            patch.object(gsa, "gsa_authenticated_request", return_value=init_resp):
        mock_user = _srp_user_mock(challenge_ok=False)
        mock_user.start_authentication.return_value = (None, "a-value")
        mock_user_cls.return_value = mock_user

        with pytest.raises(gsa.AppleAuthError):
            gsa.gsa_authenticate("user@example.com", "wrong-password")


def test_gsa_authenticate_does_not_log_response_when_m2_missing(caplog):
    secret_value = "secret-error-payload-value-should-never-be-logged"
    init_resp = {"sp": "s2k", "s": b"salt", "i": 1024, "B": b"B", "c": "c-token"}
    complete_resp = {"error-detail": secret_value}

    with caplog.at_level(logging.DEBUG), \
            patch.object(gsa.srp, "User") as mock_user_cls, \
            patch.object(gsa, "gsa_authenticated_request", side_effect=[init_resp, complete_resp]):
        mock_user = _srp_user_mock()
        mock_user.start_authentication.return_value = (None, "a-value")
        mock_user_cls.return_value = mock_user

        with pytest.raises(gsa.AppleAuthError):
            gsa.gsa_authenticate("user@example.com", "hunter2")

    assert secret_value not in caplog.text


def test_gsa_authenticate_raises_when_session_verification_fails():
    init_resp = {"sp": "s2k", "s": b"salt", "i": 1024, "B": b"B", "c": "c-token"}
    complete_resp = {"M2": b"m2", "spd": b"encrypted-spd"}

    with patch.object(gsa.srp, "User") as mock_user_cls, \
            patch.object(gsa, "gsa_authenticated_request", side_effect=[init_resp, complete_resp]), \
            patch.object(gsa, "decrypt_cbc", return_value=b"<plist><dict/></plist>"):
        mock_user = _srp_user_mock(session_key_matches=False)
        mock_user.start_authentication.return_value = (None, "a-value")
        mock_user_cls.return_value = mock_user

        with pytest.raises(gsa.AppleAuthError):
            gsa.gsa_authenticate("user@example.com", "hunter2")


def test_gsa_authenticate_interactive_dispatches_second_factor_then_retries():
    needs_2fa = gsa.NeedsSecondFactor(method="secondaryAuth", dsid="d-1", idms_token="t-1")
    with patch.object(gsa, "gsa_authenticate", side_effect=[needs_2fa, {"adsid": "a-1"}]) as mock_auth, \
            patch.object(gsa, "_dispatch_second_factor") as mock_dispatch:
        result = gsa.gsa_authenticate_interactive("user@example.com", "hunter2")

    mock_dispatch.assert_called_once_with("secondaryAuth", "d-1", "t-1")
    assert mock_auth.call_count == 2
    assert result == {"adsid": "a-1"}


def test_register_mobileme_returns_dsid_and_search_party_token():
    mobileme_plist = {
        "dsid": "dsid-1",
        "delegates": {"com.apple.mobileme": {
            "status": 0,
            "service-data": {"tokens": {"searchPartyToken": "spt-1"}},
        }},
    }
    g = {"t": {"com.apple.gs.idms.pet": {"token": "pet-1"}}, "adsid": "adsid-1"}
    resp = MagicMock()
    resp.content = b"<plist/>"
    resp.status_code = 200
    resp.text = ""
    resp.raise_for_status = MagicMock()
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=resp), \
            patch.object(gsa.plist, "loads", return_value=mobileme_plist):
        result = gsa.register_mobileme(g, "user@example.com")

    assert result == {"dsid": "dsid-1", "searchPartyToken": "spt-1"}


def test_register_mobileme_raises_on_non_zero_status():
    mobileme_plist = {
        "dsid": "dsid-1",
        "delegates": {"com.apple.mobileme": {
            "status": 1,
            "status-message": "Account is blocking",
        }},
    }
    g = {"t": {"com.apple.gs.idms.pet": {"token": "pet-1"}}, "adsid": "adsid-1"}
    resp = MagicMock()
    resp.content = b"<plist/>"
    resp.status_code = 200
    resp.text = ""
    resp.raise_for_status = MagicMock()
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False

    with patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=resp), \
            patch.object(gsa.plist, "loads", return_value=mobileme_plist):
        with pytest.raises(gsa.AppleAuthError, match="Account is blocking"):
            gsa.register_mobileme(g, "user@example.com")


def test_register_mobileme_does_not_log_search_party_token(caplog):
    secret_token = "super-secret-search-party-token-value"
    mobileme_plist = {
        "dsid": "dsid-1",
        "delegates": {"com.apple.mobileme": {
            "status": 0,
            "service-data": {"tokens": {"searchPartyToken": secret_token}},
        }},
    }
    g = {"t": {"com.apple.gs.idms.pet": {"token": "pet-1"}}, "adsid": "adsid-1"}
    resp = MagicMock()
    resp.content = b"<plist/>"
    resp.status_code = 200
    # A real response body would contain the token in cleartext - simulate
    # that here to prove the logging call never includes resp.text.
    resp.text = f"<plist><key>searchPartyToken</key><string>{secret_token}</string></plist>"
    resp.raise_for_status = MagicMock()
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False

    with caplog.at_level(logging.DEBUG), \
            patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.requests, "post", return_value=resp), \
            patch.object(gsa.plist, "loads", return_value=mobileme_plist):
        gsa.register_mobileme(g, "user@example.com")

    assert secret_token not in caplog.text


def test_gsa_authenticated_request_does_not_log_raw_response_body(caplog):
    secret_marker = "secret-session-proof-value-should-never-be-logged"
    resp = MagicMock()
    resp.content = b"<plist/>"
    resp.status_code = 200
    resp.text = f"<plist><key>M2</key><string>{secret_marker}</string></plist>"
    resp.raise_for_status = MagicMock()
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False

    with caplog.at_level(logging.DEBUG), \
            patch.object(gsa.requests, "post", return_value=resp), \
            patch.object(gsa, "generate_anisette_headers", return_value={}), \
            patch.object(gsa.plist, "loads", return_value={"Response": {"ok": True}}):
        gsa.gsa_authenticated_request({"o": "init"})

    assert secret_marker not in caplog.text
