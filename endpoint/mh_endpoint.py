#!/usr/bin/env python3

import base64
import json
import logging
import os
import ssl
import sys
import threading
import time
from datetime import datetime,  timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

import requests

import mh_config
from history import archiver as history_archiver
from history.store import HistoryStore
from register import apple_cryptography, pypush_gsa_icloud

logger = logging.getLogger()

history_store = None


class ServerHandler(BaseHTTPRequestHandler):

    def addCORSHeaders(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header("Access-Control-Allow-Headers", "X-Requested-With")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Headers", "Authorization")
        self.send_header("Access-Control-Allow-Private-Network","true")

    def authenticate(self):
        endpoint_user = mh_config.getEndpointUser()
        endpoint_pass = mh_config.getEndpointPass()
        if (endpoint_user is None or endpoint_user == "") and (endpoint_pass is None or endpoint_pass == ""):
            return True

        auth_header = self.headers.get('authorization')
        if auth_header:
            auth_type, auth_encoded = auth_header.split(None, 1)
            if auth_type.lower() == 'basic':
                auth_decoded = base64.b64decode(auth_encoded).decode('utf-8')
                username, password = auth_decoded.split(':', 1)
                if username == endpoint_user and password == endpoint_pass:
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
        self.send_response(200)
        self.addCORSHeaders()
        self.send_header('Content-type', 'text/plain')
        self.end_headers()
        self.wfile.write(b"Nothing to see here")

    def do_POST(self):
        if not self.authenticate():
            self.send_response(401)
            self.addCORSHeaders()
            self.send_header('WWW-Authenticate', 'Basic realm="Auth Realm"')
            self.end_headers()
            return
        if hasattr(self.headers, 'getheader'):
            content_len = int(self.headers.getheader('content-length', 0))
        else:
            content_len = int(self.headers.get('content-length'))

        post_body = self.rfile.read(content_len)

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
                r.raise_for_status()
            return json.loads(r.content.decode())['results']

        try:
            results = history_archiver.fetch_reports_with_cache(
                ids, days, force, history_store,
                mh_config.getHistoryPollIntervalHours(), fetch_from_apple,
            )

            self.send_response(200)
            self.addCORSHeaders()
            self.end_headers()

            responseBody = json.dumps({"results": results})
            self.wfile.write(responseBody.encode())
        except requests.exceptions.ConnectTimeout:
            logger.error("Timeout to " + mh_config.getAnisetteServer() +
                         ", is your anisette running and accepting Connections?")
            self.send_response(504)
        except Exception as e:
            logger.error(f"Unknown error occurred {e}", exc_info=True)
            self.send_response(501)

    def getCurrentTimes(self):
        clientTime = datetime.now(timezone.utc).replace(microsecond=0).isoformat() + 'Z'
        clientTimestamp = int(datetime.now().strftime('%s'))
        return clientTime, time.tzname[1], clientTimestamp


def getAuth(regenerate=False, second_factor='sms'):
    if os.path.exists(mh_config.getConfigFile()) and not regenerate:
        with open(mh_config.getConfigFile(), "r") as f:
            j = json.load(f)
    else:
        mobileme = pypush_gsa_icloud.icloud_login_mobileme(username=mh_config.USER, password=mh_config.PASS)
        logger.debug('Mobileme result: ' + mobileme)
        j = {'dsid': mobileme['dsid'], 'searchPartyToken': mobileme['delegates']
             ['com.apple.mobileme']['service-data']['tokens']['searchPartyToken']}
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

    devices_file_path = mh_config.getConfigPath() + '/' + mh_config.getHistoryDevicesFile()
    if os.path.isfile(devices_file_path):
        history_store = HistoryStore(mh_config.getConfigPath() + '/history.db')

        def fetch_from_apple(fetch_ids):
            data = {"search": [{"startDate": 1, "ids": fetch_ids}]}
            with requests.post("https://gateway.icloud.com/acsnservice/fetch",
                                auth=getAuth(regenerate=False, second_factor='sms'),
                                headers=pypush_gsa_icloud.generate_anisette_headers(),
                                json=data) as r:
                r.raise_for_status()
            return json.loads(r.content.decode())['results']

        archiver_thread = threading.Thread(
            target=history_archiver.run_archiver_loop,
            args=(devices_file_path, history_store, mh_config.getHistoryPollIntervalHours(), fetch_from_apple),
            daemon=True,
        )
        archiver_thread.start()
        logger.info(f"History archiver started, tracking devices from {devices_file_path}")
    else:
        logger.info(f"No history devices file at {devices_file_path}, history archiving disabled")

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
    user = mh_config.getEndpointUser()
    passw = mh_config.getEndpointPass()
    if (user is None or user == "") and (passw is None or passw == ""):
        logger.warning("Endpoint is not protected by authentication")
    else:
        logger.info("Endpoint is protected by authentication")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        logger.info('Server stopped')
