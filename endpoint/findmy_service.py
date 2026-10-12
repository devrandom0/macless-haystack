import os
import json
import logging
from typing import Any, Dict, List, Optional
from findmy import AppleAccount, RemoteAnisetteProvider, KeyPair, LocationReport
from findmy.reports import LoginState

logger = logging.getLogger(__name__)

class FindMyService:
    def __init__(self, anisette_url: str = "http://anisette:6969", storage_path: str = "data/findmy_account.json"):
        self.anisette_url = anisette_url
        self.storage_path = storage_path
        self._provider = RemoteAnisetteProvider(self.anisette_url)
        self._account: Optional[AppleAccount] = None
        self._load_saved_account()

    def _load_saved_account(self):
        if os.path.exists(self.storage_path):
            try:
                self._account = AppleAccount.from_json(self.storage_path)
                logger.info("Restored FindMy account from %s", self.storage_path)
            except Exception as e:
                logger.warning("Could not restore FindMy account: %s", e)
                self._account = None

    def get_status(self) -> Dict[str, Any]:
        if not self._account:
            return {"logged_in": False, "state": "LOGGED_OUT"}
        is_logged_in = self._account.login_state == LoginState.LOGGED_IN
        return {
            "logged_in": is_logged_in,
            "state": str(self._account.login_state.name if hasattr(self._account.login_state, "name") else self._account.login_state),
            "account_name": self._account.account_name,
            "first_name": self._account.first_name,
            "last_name": self._account.last_name,
        }

    def login(self, username: str, password: str) -> Dict[str, Any]:
        self._account = AppleAccount(self._provider)
        state = self._account.login(username, password)
        state_str = state.name if hasattr(state, "name") else str(state)
        if state == LoginState.LOGGED_IN:
            os.makedirs(os.path.dirname(os.path.abspath(self.storage_path)), exist_ok=True)
            self._account.to_json(self.storage_path)
            return {"logged_in": True, "state": state_str}
        return {"logged_in": False, "state": state_str}

    def submit_2fa(self, code: str, method: str = "trusted_device") -> Dict[str, Any]:
        if not self._account:
            return {"success": False, "error": "No account login in progress"}
        if method == "sms":
            methods = self._account.get_2fa_methods()
            phone_id = methods[0].phone_number_id if methods else 0
            state = self._account.sms_2fa_submit(phone_id, code)
        else:
            state = self._account.td_2fa_submit(code)
        state_str = state.name if hasattr(state, "name") else str(state)
        if state == LoginState.LOGGED_IN:
            os.makedirs(os.path.dirname(os.path.abspath(self.storage_path)), exist_ok=True)
            self._account.to_json(self.storage_path)
            return {"success": True, "state": state_str}
        return {"success": False, "state": state_str}

    def format_report(self, report: LocationReport) -> Dict[str, Any]:
        return {
            "lat": report.latitude,
            "lon": report.longitude,
            "accuracy": report.horizontal_accuracy,
            "confidence": report.confidence,
            "status": report.status,
            "timestamp": report.timestamp.isoformat() if hasattr(report.timestamp, "isoformat") else str(report.timestamp),
        }

    def fetch_reports_for_key(self, private_key_b64: str) -> List[Dict[str, Any]]:
        if not self._account or self._account.login_state != LoginState.LOGGED_IN:
            return []
        key = KeyPair.from_b64(private_key_b64)
        reports = self._account.fetch_location_history(key)
        if isinstance(reports, list):
            return [self.format_report(r) for r in reports]
        return []
