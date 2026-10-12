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
        account_name = None
        first_name = None
        last_name = None
        if is_logged_in:
            try:
                account_name = self._account.account_name
                first_name = self._account.first_name
                last_name = self._account.last_name
            except Exception:
                pass
        return {
            "logged_in": is_logged_in,
            "state": str(self._account.login_state.name if hasattr(self._account.login_state, "name") else self._account.login_state),
            "account_name": account_name,
            "first_name": first_name,
            "last_name": last_name,
        }

    def login(self, username: str, password: str) -> Dict[str, Any]:
        try:
            self._account = AppleAccount(self._provider)
            state = self._account.login(username, password)
            state_str = state.name if hasattr(state, "name") else str(state)
            if state == LoginState.LOGGED_IN:
                os.makedirs(os.path.dirname(os.path.abspath(self.storage_path)), exist_ok=True)
                self._account.to_json(self.storage_path)
                return {"logged_in": True, "state": state_str}
            return {"logged_in": False, "state": state_str}
        except Exception as e:
            logger.error("Login failed: %s", e)
            return {"logged_in": False, "state": "ERROR", "error": str(e)}

    def submit_2fa(self, code: str, method: str = "trusted_device") -> Dict[str, Any]:
        if not self._account:
            return {"success": False, "error": "No account login in progress"}
        try:
            if method == "sms":
                methods = self._account.get_2fa_methods()
                sms_methods = [m for m in methods if hasattr(m, "phone_number_id")]
                if not sms_methods:
                    return {"success": False, "error": "No SMS 2FA method available"}
                phone_id = sms_methods[0].phone_number_id
                state = self._account.sms_2fa_submit(phone_id, code)
            else:
                state = self._account.td_2fa_submit(code)
            state_str = state.name if hasattr(state, "name") else str(state)
            if state == LoginState.LOGGED_IN:
                os.makedirs(os.path.dirname(os.path.abspath(self.storage_path)), exist_ok=True)
                self._account.to_json(self.storage_path)
                return {"success": True, "state": state_str}
            return {"success": False, "state": state_str}
        except Exception as e:
            logger.error("2FA submission failed: %s", e)
            return {"success": False, "error": str(e)}

    def format_report(self, report: LocationReport) -> Dict[str, Any]:
        return {
            "lat": report.latitude,
            "lon": report.longitude,
            "accuracy": report.horizontal_accuracy,
            "confidence": report.confidence,
            "status": report.status,
            "timestamp": report.timestamp.isoformat() if hasattr(report.timestamp, "isoformat") else str(report.timestamp),
        }

    def list_devices(self) -> List[Dict[str, Any]]:
        devices_file = os.path.join(os.path.dirname(os.path.abspath(self.storage_path)), "registered_devices.json")
        if os.path.exists(devices_file):
            try:
                with open(devices_file, "r") as f:
                    return json.load(f)
            except Exception as e:
                logger.error("Error reading registered_devices.json: %s", e)
        return []

    def register_device(self, device_data: Dict[str, Any]) -> bool:
        if not isinstance(device_data, dict) or not device_data.get("id"):
            return False
        devices_file = os.path.join(os.path.dirname(os.path.abspath(self.storage_path)), "registered_devices.json")
        devices = self.list_devices()
        device_id = str(device_data["id"])
        updated = False
        for idx, d in enumerate(devices):
            if str(d.get("id")) == device_id:
                devices[idx] = device_data
                updated = True
                break
        if not updated:
            devices.append(device_data)
        os.makedirs(os.path.dirname(devices_file), exist_ok=True)
        with open(devices_file, "w") as f:
            json.dump(devices, f, indent=2)
        return True

    def fetch_reports_for_key(self, private_key_b64: str) -> List[Dict[str, Any]]:
        if not self._account or self._account.login_state != LoginState.LOGGED_IN:
            return []
        try:
            key = KeyPair.from_b64(private_key_b64)
            reports = self._account.fetch_location_history(key)
            if isinstance(reports, list):
                return [self.format_report(r) for r in reports]
        except Exception as e:
            logger.error("Failed to fetch reports for key: %s", e)
        return []
