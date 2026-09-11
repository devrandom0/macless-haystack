import os
import sys

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
ENDPOINT_DIR = os.path.dirname(TESTS_DIR)
REPO_ROOT = os.path.dirname(ENDPOINT_DIR)

for path in (ENDPOINT_DIR, REPO_ROOT):
    if path not in sys.path:
        sys.path.insert(0, path)
