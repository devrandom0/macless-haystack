import logging
import os
import configparser
import sys

sys.path.append(os.getcwd())

CONFIG_PATH = "data"
CONFIG_FILE = "auth.json"
CERT_FILE = "certificate.pem"  # optional
KEY_FILE = "privkey.pem"  # optional


def getConfigPath():
    script_path = os.path.abspath(__file__)
    return CONFIG_PATH if os.path.isabs(CONFIG_PATH) else os.path.dirname(script_path) + '/' + CONFIG_PATH


config = configparser.ConfigParser()
config.read(getConfigPath() + '/config.ini')


def getAnisetteServer():
    return config.get('Settings', 'anisette_url', fallback='http://anisette:6969')


def getPort():
    return int(config.get('Settings', 'port', fallback='6176'))


def getBindingAddress():
    return config.get('Settings', 'binding_address', fallback='0.0.0.0')


def getUser():
    return config.get('Settings', 'appleid', fallback=None)


def getPass():
    return config.get('Settings', 'appleid_pass', fallback=None)


def getConfigFile():
    return getConfigPath() + '/' + CONFIG_FILE


def getCertFile():
    return getConfigPath() + '/' + config.get('Settings', 'cert', fallback=CERT_FILE)


def getKeyFile():
    return getConfigPath() + '/' + config.get('Settings', 'priv_key', fallback=KEY_FILE)


def getEndpointUser():
    return config.get('Settings', 'endpoint_user', fallback=None)


def getEndpointPass():
    return config.get('Settings', 'endpoint_pass', fallback=None)


def getBasicAuthUsers():
    """Additional Basic Auth users beyond the single legacy endpoint_user/
    endpoint_pass pair, as {username: password}. Configured via a
    [BasicAuthUsers] section in config.ini, one `username = password` line
    per user (usernames are stored lowercase by ConfigParser, so use
    lowercase usernames there).

    config.items(section) would otherwise merge in every [DEFAULT] option
    (turning e.g. appleid_pass into a working Basic Auth password) and
    apply % interpolation (a literal % in a password raises
    InterpolationSyntaxError) - raw=True plus filtering out the defaults
    avoids both.
    """
    if not config.has_section('BasicAuthUsers'):
        return {}
    defaults = config.defaults()
    return {k: v for k, v in config.items('BasicAuthUsers', raw=True) if k not in defaults}


def getHistoryDevicesFile():
    return config.get('Settings', 'history_devices_file', fallback='devices.json')


def getHistoryPollIntervalHours():
    return float(config.get('Settings', 'history_poll_interval_hours', fallback='4'))


def getHistoryMasterKeyFile():
    return config.get('Settings', 'history_master_key_file', fallback='history_key.bin')


def getLogLevel():
    logLevel = config.get('Settings', 'loglevel', fallback='INFO')
    return logging.getLevelName(logLevel)


logging.basicConfig(level=getLogLevel(),
                    format='%(asctime)s - %(levelname)s - %(message)s')
# Suppress http-log
logging.getLogger('urllib3').setLevel(logging.INFO)
