#!/usr/bin/env python3

import base64
import json
import logging
import math
import os
import ssl
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime,  timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

import requests

import mh_config
from history import archiver as history_archiver
from history import crypto
from history.registry import TrackedDeviceStore
from history.store import HistoryStore
from register import apple_cryptography, pypush_gsa_icloud
import web_static

logger = logging.getLogger()

history_store = None
tracked_device_store = None
history_encryption_key = None

WEB_ROOT = Path(__file__).resolve().parent / 'web_dist'

PENDING_LOGIN_TIMEOUT_SECONDS = 600


@dataclass
class PendingAppleLogin:
    method: str
    state: dict
    username: str
    password: str
    started_at: float


pending_apple_login = None
apple_session_stale = False


class ServerHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        # Route the access log through the same `logging` config as the app's own
        # DEBUG/INFO logs, instead of BaseHTTPRequestHandler's default which writes
        # straight to stderr with its own timestamp/format, independent of `logging`.
        message = format % args
        control_char_table = getattr(self, '_control_char_table', None)
        if control_char_table is not None:
            message = message.translate(control_char_table)
        logger.info("%s - - %s", self.address_string(), message)

    def addCORSHeaders(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header("Access-Control-Allow-Headers", "X-Requested-With")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Headers", "Authorization")
        self.send_header("Access-Control-Allow-Private-Network","true")

    def _send_json(self, status, body):
        self.send_response(status)
        self.addCORSHeaders()
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def authenticate(self):
        endpoint_user = mh_config.getEndpointUser()
        endpoint_pass = mh_config.getEndpointPass()
        basic_auth_users = mh_config.getBasicAuthUsers()
        has_legacy_pair = _has_legacy_credentials(endpoint_user, endpoint_pass)
        if not has_legacy_pair and not basic_auth_users:
            return True

        auth_header = self.headers.get('authorization')
        if auth_header:
            auth_type, auth_encoded = auth_header.split(None, 1)
            if auth_type.lower() == 'basic':
                auth_decoded = base64.b64decode(auth_encoded).decode('utf-8')
                username, password = auth_decoded.split(':', 1)
                if has_legacy_pair and username == endpoint_user and password == endpoint_pass:
                    return True
                if username in basic_auth_users and password == basic_auth_users[username]:
                    return True

        return False

    def do_OPTIONS(self):
        self.send_response(200, "ok")
        self.addCORSHeaders()
        self.end_headers()

    def do_GET(self):
        if not self.authenticate():
            self.send_response(401)
            self.addCORSHeaders()
            self.send_header('WWW-Authenticate', 'Basic realm="Auth Realm"')
            self.end_headers()
            return

        path = urlparse(self.path).path
        if path.startswith('/webapp'):
            self._serve_static(path)
            return

        if path == '/history/devices':
            if tracked_device_store is None:
                self.send_response(503)
                self.addCORSHeaders()
                self.end_headers()
                self.wfile.write(json.dumps({"error": "history archiving unavailable"}).encode())
                return
            self.send_response(200)
            self.addCORSHeaders()
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"devices": tracked_device_store.list_devices()}).encode())
            return

        if path == '/auth/apple/status':
            self._handle_get_auth_apple_status()
            return

        self.send_response(200)
        self.addCORSHeaders()
        self.send_header('Content-type', 'text/plain')
        self.end_headers()
        self.wfile.write(b"Nothing to see here")

    def _serve_static(self, path):
        try:
            resolved = web_static.resolve_static_path(path, WEB_ROOT)
            data = resolved.read_bytes() if resolved is not None else None
        except OSError as e:
            logger.warning(f"Error serving static file for {path}: {e}")
            self.send_response(500)
            self.addCORSHeaders()
            self.end_headers()
            return

        if data is None:
            self.send_response(404)
            self.addCORSHeaders()
            self.end_headers()
            return

        self.send_response(200)
        self.addCORSHeaders()
        self.send_header('Content-type', web_static.guess_content_type(resolved))
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if not self.authenticate():
            self.send_response(401)
            self.addCORSHeaders()
            self.send_header('WWW-Authenticate', 'Basic realm="Auth Realm"')
            self.end_headers()
            # Drain any unread body so the socket doesn't close with
            # buffered inbound data, which makes the OS send a TCP RST
            # instead of a clean close and can reset the client's read.
            content_len = int(self.headers.get('content-length', 0) or 0)
            if content_len:
                self.rfile.read(content_len)
            return
        if hasattr(self.headers, 'getheader'):
            content_len = int(self.headers.getheader('content-length', 0))
        else:
            # A request with no body at all (e.g. POST /auth/apple/logout)
            # omits Content-Length entirely, and .get(...) with no default
            # returns None - int(None) crashes the whole connection with no
            # HTTP response at all. Matches the same "or 0" guard already
            # used above for the unauthenticated-request branch.
            content_len = int(self.headers.get('content-length', 0) or 0)

        post_body = self.rfile.read(content_len)

        path = urlparse(self.path).path
        if path == '/history/devices':
            try:
                body = json.loads(post_body)
            except json.JSONDecodeError as e:
                self.send_response(400)
                self.addCORSHeaders()
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())
                return
            self._handle_post_history_devices(body)
            return

        if path == '/auth/apple/login':
            try:
                body = json.loads(post_body)
            except json.JSONDecodeError as e:
                self._send_json(400, {"error": str(e)})
                return
            self._handle_post_auth_apple_login(body)
            return

        if path == '/auth/apple/verify':
            try:
                body = json.loads(post_body)
            except json.JSONDecodeError as e:
                self._send_json(400, {"error": str(e)})
                return
            self._handle_post_auth_apple_verify(body)
            return

        if path == '/auth/apple/logout':
            self._handle_post_auth_apple_logout()
            return

        logger.debug('Getting with post: ' + str(post_body))
        body = json.loads(post_body)

        days = body.get('days', 7)
        force = body.get('force', False)
        ids = list(body['ids'])
        logger.debug('Querying for ' + str(days) + ' days')

        def fetch_from_apple(fetch_ids):
            data = {"search": [{"startDate": 1, "ids": fetch_ids}]}
            with requests.post("https://gateway.icloud.com/acsnservice/fetch",
                                auth=getAuth(regenerate=False, second_factor='sms'),
                                headers=pypush_gsa_icloud.generate_anisette_headers(),
                                json=data) as r:
                _raise_for_status_marking_stale(r)
            return json.loads(r.content.decode())['results']

        try:
            results, new_count = history_archiver.fetch_reports_with_cache(
                ids, days, force, history_store,
                mh_config.getHistoryPollIntervalHours(), fetch_from_apple,
            )

            self.send_response(200)
            self.addCORSHeaders()
            self.end_headers()

            responseBody = json.dumps({"results": results, "new_count": new_count})
            self.wfile.write(responseBody.encode())
        except requests.exceptions.ConnectTimeout:
            logger.error("Timeout to " + mh_config.getAnisetteServer() +
                         ", is your anisette running and accepting Connections?")
            self.send_response(504)
        except Exception as e:
            logger.error(f"Unknown error occurred {e}", exc_info=True)
            self.send_response(501)

    def _handle_post_history_devices(self, body):
        if tracked_device_store is None or history_encryption_key is None:
            self.send_response(503)
            self.addCORSHeaders()
            self.end_headers()
            self.wfile.write(json.dumps({"error": "history archiving unavailable"}).encode())
            return

        try:
            devices = body['devices']
            if not isinstance(devices, list):
                raise ValueError("'devices' must be a list")
            now = int(time.time())
            parsed = []
            for device in devices:
                hashed_public_key = device['hashedPublicKey']
                private_key = device['privateKey']
                name = device['name']
                if not isinstance(hashed_public_key, str):
                    raise TypeError("'hashedPublicKey' must be a string")
                if not isinstance(private_key, str):
                    raise TypeError("'privateKey' must be a string")
                if not isinstance(name, str):
                    raise TypeError("'name' must be a string")
                accessory_id = device.get('accessoryId')
                if accessory_id is not None and not isinstance(accessory_id, str):
                    raise TypeError("'accessoryId' must be a string or null")
                previous = tracked_device_store.get_device(hashed_public_key)
                default_poll_interval_hours = previous["pollIntervalHours"] if previous is not None else 4
                default_retention_days = previous["retentionDays"] if previous is not None else 30
                # Upper bounds are generous (well past any sane real-world
                # value) but exist so an absurd input can't overflow SQLite's
                # integer range in downstream retention-cutoff arithmetic.
                poll_interval_hours = device.get('pollIntervalHours', default_poll_interval_hours)
                if (not isinstance(poll_interval_hours, (int, float)) or isinstance(poll_interval_hours, bool)
                        or not math.isfinite(poll_interval_hours)
                        or not 1 <= poll_interval_hours <= 720):
                    raise ValueError(
                        "'pollIntervalHours' must be between 1 and 720 "
                        "(to avoid triggering Apple's rate limits and to stay within a sane range)")
                retention_days = device.get('retentionDays', default_retention_days)
                if (not isinstance(retention_days, (int, float)) or isinstance(retention_days, bool)
                        or not math.isfinite(retention_days) or retention_days != int(retention_days)
                        or not 1 <= retention_days <= 3650):
                    raise ValueError("'retentionDays' must be a whole number between 1 and 3650")
                parsed.append((
                    hashed_public_key,
                    private_key,
                    name,
                    accessory_id,
                    bool(device['enabled']),
                    poll_interval_hours,
                    int(retention_days),
                    previous,
                ))
        except (KeyError, ValueError, TypeError) as e:
            self.send_response(400)
            self.addCORSHeaders()
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())
            return

        try:
            for (hashed_public_key, private_key, name, accessory_id, enabled, poll_interval_hours,
                 retention_days, previous) in parsed:
                encrypted = crypto.encrypt(history_encryption_key, private_key)
                tracked_device_store.upsert(
                    hashed_public_key, name, accessory_id, encrypted, enabled,
                    poll_interval_hours=poll_interval_hours, retention_days=retention_days, when=now,
                )
                if previous is not None and retention_days < previous["retentionDays"] and history_store is not None:
                    history_store.delete_reports_older_than(hashed_public_key, now - retention_days * 86400)
        except Exception as e:
            logger.error(f"Failed to persist tracked devices: {e}", exc_info=True)
            self.send_response(500)
            self.addCORSHeaders()
            self.end_headers()
            self.wfile.write(json.dumps({"error": "internal server error"}).encode())
            return

        self.send_response(200)
        self.addCORSHeaders()
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok"}).encode())

    def _handle_post_auth_apple_login(self, body):
        global pending_apple_login

        # Even when this attempt fails, a stored password must not outlive it.
        pending_apple_login = None

        try:
            username = body['username']
            password = body['password']
            if not isinstance(username, str) or not isinstance(password, str):
                raise TypeError("'username' and 'password' must be strings")
        except (KeyError, TypeError) as e:
            self._send_json(400, {"error": str(e)})
            return

        try:
            result = pypush_gsa_icloud.gsa_authenticate(username, password)
        except pypush_gsa_icloud.AppleAuthError:
            pending_apple_login = None
            self._send_json(401, {"error": "invalid_credentials"})
            return
        except requests.exceptions.RequestException:
            self._send_json(502, {"error": "apple_unreachable"})
            return

        if isinstance(result, pypush_gsa_icloud.NeedsSecondFactor):
            try:
                state = pypush_gsa_icloud.request_second_factor_code(
                    result.method, result.dsid, result.idms_token)
            except requests.exceptions.RequestException:
                self._send_json(502, {"error": "apple_unreachable"})
                return
            pending_apple_login = PendingAppleLogin(
                method=result.method, state=state, username=username, password=password,
                started_at=time.time(),
            )
            self._send_json(200, {
                "status": "code_required",
                "method": _SECOND_FACTOR_METHOD_NAMES[result.method],
            })
            return

        try:
            _complete_apple_login(result, username)
        except pypush_gsa_icloud.AppleAuthError as e:
            self._send_json(401, {"error": "account_error", "message": str(e)})
            return
        except requests.exceptions.RequestException:
            self._send_json(502, {"error": "apple_unreachable"})
            return

        pending_apple_login = None
        self._send_json(200, {"status": "authenticated"})

    def _handle_post_auth_apple_verify(self, body):
        global pending_apple_login

        pending = pending_apple_login
        if pending is None:
            self._send_json(409, {"error": "no_pending_login"})
            return
        if time.time() - pending.started_at > PENDING_LOGIN_TIMEOUT_SECONDS:
            pending_apple_login = None
            self._send_json(410, {"error": "login_expired"})
            return

        try:
            code = body['code']
            if not isinstance(code, str):
                raise TypeError("'code' must be a string")
        except (KeyError, TypeError) as e:
            self._send_json(400, {"error": str(e)})
            return

        try:
            pypush_gsa_icloud.submit_second_factor_code(pending.method, pending.state, code)
        except pypush_gsa_icloud.AppleAuthError:
            pending_apple_login = None
            self._send_json(401, {"error": "invalid_code"})
            return
        except requests.exceptions.RequestException:
            self._send_json(502, {"error": "apple_unreachable"})
            return

        try:
            result = pypush_gsa_icloud.gsa_authenticate(pending.username, pending.password)
        except pypush_gsa_icloud.AppleAuthError:
            pending_apple_login = None
            self._send_json(401, {"error": "invalid_code"})
            return
        except requests.exceptions.RequestException:
            self._send_json(502, {"error": "apple_unreachable"})
            return

        if isinstance(result, pypush_gsa_icloud.NeedsSecondFactor):
            # The trusted-device flow doesn't signal a wrong code at submit
            # time (see submit_trusted_device_code) - Apple demanding
            # another round of 2FA immediately after is how a wrong code
            # shows up here instead.
            pending_apple_login = None
            self._send_json(401, {"error": "invalid_code"})
            return

        try:
            _complete_apple_login(result, pending.username)
        except pypush_gsa_icloud.AppleAuthError as e:
            pending_apple_login = None
            self._send_json(401, {"error": "account_error", "message": str(e)})
            return
        except requests.exceptions.RequestException:
            self._send_json(502, {"error": "apple_unreachable"})
            return

        pending_apple_login = None
        self._send_json(200, {"status": "authenticated"})

    def _handle_get_auth_apple_status(self):
        _expire_pending_login_if_stale()
        logged_in = os.path.exists(mh_config.getConfigFile()) and not apple_session_stale
        self._send_json(200, {"loggedIn": logged_in, "pending": pending_apple_login is not None})

    def _handle_post_auth_apple_logout(self):
        global apple_session_stale, pending_apple_login
        # Clear in-memory state first, regardless of what happens below, so
        # a failed file removal never strands a pending login's password.
        apple_session_stale = False
        pending_apple_login = None
        try:
            os.remove(mh_config.getConfigFile())
        except FileNotFoundError:
            pass
        except OSError as e:
            self._send_json(500, {"error": "logout_failed", "message": str(e)})
            return
        self._send_json(200, {"status": "logged_out"})

    def getCurrentTimes(self):
        clientTime = datetime.now(timezone.utc).replace(microsecond=0).isoformat() + 'Z'
        clientTimestamp = int(datetime.now().strftime('%s'))
        return clientTime, time.tzname[1], clientTimestamp


_SECOND_FACTOR_METHOD_NAMES = {
    "trustedDeviceSecondaryAuth": "trusted_device",
    "secondaryAuth": "sms",
}


def _has_legacy_credentials(endpoint_user, endpoint_pass):
    return not ((endpoint_user is None or endpoint_user == "") and (endpoint_pass is None or endpoint_pass == ""))


def _log_auth_status():
    if _has_legacy_credentials(mh_config.getEndpointUser(), mh_config.getEndpointPass()) or mh_config.getBasicAuthUsers():
        logger.info("Endpoint is protected by authentication")
    else:
        logger.warning("Endpoint is not protected by authentication")


def _expire_pending_login_if_stale():
    global pending_apple_login
    if pending_apple_login is not None and time.time() - pending_apple_login.started_at > PENDING_LOGIN_TIMEOUT_SECONDS:
        pending_apple_login = None


def _complete_apple_login(g, username):
    """Finishes a successful GSA login: registers the device with mobileme
    and writes the resulting session to auth.json. Raises AppleAuthError on
    a bad account status, or a requests exception on a network failure."""
    global apple_session_stale
    j = pypush_gsa_icloud.register_mobileme(g, username)
    with open(mh_config.getConfigFile(), "w") as f:
        json.dump(j, f)
    apple_session_stale = False


def _raise_for_status_marking_stale(response):
    global apple_session_stale
    try:
        response.raise_for_status()
    except requests.exceptions.HTTPError:
        if response.status_code in (401, 403):
            apple_session_stale = True
        raise


def getAuth(regenerate=False, second_factor='sms'):
    if os.path.exists(mh_config.getConfigFile()) and not regenerate:
        with open(mh_config.getConfigFile(), "r") as f:
            j = json.load(f)
    else:
        user = mh_config.getUser()
        password = mh_config.getPass()
        if not user or not password:
            # This is a server process with no interactive terminal in the
            # in-app-login workflow - falling through to
            # icloud_login_mobileme's input()/getpass() prompts here would
            # block this single-threaded HTTPServer forever (or spin on
            # EOFError every request if stdin isn't a tty). Log in again via
            # the app instead of configuring appleid/appleid_pass.
            raise RuntimeError(
                "No Apple session available and no appleid/appleid_pass configured in "
                "config.ini - log in again via the app's in-app Apple ID login.")
        j = pypush_gsa_icloud.icloud_login_mobileme(username=user, password=password)
        with open(mh_config.getConfigFile(), "w") as f:
            json.dump(j, f)
    return j['dsid'], j['searchPartyToken']



def check_if_anisette_is_reachable(max_retries=3, retry_delay=10):
    server_url = mh_config.getAnisetteServer()
    logging.info(f'Checking if Anisette {server_url} is reachable')
    for attempt in range(max_retries):
        try:
            response = requests.get(server_url, timeout=5)
            response.raise_for_status()
            return
        except (requests.RequestException, requests.HTTPError) as e:
            logger.error(f"Attempt {attempt + 1} failed: {str(e)}")
            if attempt < max_retries - 1:
                logger.error(f"Retrying in {retry_delay} seconds...")
                time.sleep(retry_delay)
    logger.error(f"Max retries reached. Program will exit. Make sure your Anisette is reachable and start again with 'docker start -ai macless-haystack'")
    sys.exit()

if __name__ == "__main__":
    check_if_anisette_is_reachable()
    logging.info(f'Searching for token at ' + mh_config.getConfigFile())
    if not os.path.exists(mh_config.getConfigFile()):
        logging.info(f'No auth-token found.')
        apple_cryptography.registerDevice()

    def fetch_from_apple(fetch_ids):
        data = {"search": [{"startDate": 1, "ids": fetch_ids}]}
        with requests.post("https://gateway.icloud.com/acsnservice/fetch",
                            auth=getAuth(regenerate=False, second_factor='sms'),
                            headers=pypush_gsa_icloud.generate_anisette_headers(),
                            json=data) as r:
            _raise_for_status_marking_stale(r)
        return json.loads(r.content.decode())['results']

    try:
        history_store = HistoryStore(mh_config.getConfigPath() + '/history.db')
        tracked_device_store = TrackedDeviceStore(mh_config.getConfigPath() + '/history.db')
        history_encryption_key = crypto.load_or_create_key(
            mh_config.getConfigPath() + '/' + mh_config.getHistoryMasterKeyFile())
    except Exception as e:
        logger.error(f"Could not open history database, archiving disabled: {e}", exc_info=True)
        history_store = None
        tracked_device_store = None
        history_encryption_key = None

    if history_store is not None and tracked_device_store is not None:
        devices_file_path = mh_config.getConfigPath() + '/' + mh_config.getHistoryDevicesFile()
        history_archiver.migrate_devices_json_to_registry(
            devices_file_path, tracked_device_store, history_encryption_key)

        archiver_thread = threading.Thread(
            target=history_archiver.run_archiver_loop,
            args=(tracked_device_store, history_store, fetch_from_apple),
            daemon=True,
        )
        archiver_thread.start()
        logger.info("History archiver started")
    else:
        logger.info("History store unavailable, archiving disabled")

    Handler = ServerHandler

    httpd = HTTPServer((mh_config.getBindingAddress(), mh_config.getPort()), Handler)
    httpd.timeout = 30
    address = mh_config.getBindingAddress() + ":" + str(mh_config.getPort())
    if os.path.isfile(mh_config.getCertFile()):
        logger.info("Certificate file " + mh_config.getCertFile() +
                    " exists, so using SSL")
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.load_cert_chain(certfile=mh_config.getCertFile(
        ), keyfile=mh_config.getKeyFile() if os.path.isfile(mh_config.getKeyFile()) else None)

        httpd.socket = ssl_context.wrap_socket(httpd.socket, server_side=True)

        logger.info("serving at " + address + " over HTTPS")
    else:
        logger.info("Certificate file " + mh_config.getCertFile() +
                    " not found, so not using SSL")
        logger.info("serving at " + address + " over HTTP")
    _log_auth_status()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        logger.info('Server stopped')
