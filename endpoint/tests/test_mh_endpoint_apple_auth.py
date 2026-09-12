from unittest.mock import patch

import mh_config
import mh_endpoint


def test_get_auth_regenerates_using_configured_user_and_pass(tmp_path, monkeypatch):
    monkeypatch.setattr(mh_config, "getConfigFile", lambda: str(tmp_path / "auth.json"))
    monkeypatch.setattr(mh_config, "getUser", lambda: "user@example.com")
    monkeypatch.setattr(mh_config, "getPass", lambda: "hunter2")

    with patch.object(
        mh_endpoint.pypush_gsa_icloud, "icloud_login_mobileme",
        return_value={"dsid": "dsid-1", "searchPartyToken": "spt-1"},
    ) as mock_login:
        dsid, token = mh_endpoint.getAuth(regenerate=True)

    mock_login.assert_called_once_with(username="user@example.com", password="hunter2")
    assert (dsid, token) == ("dsid-1", "spt-1")
