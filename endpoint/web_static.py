import mimetypes
from pathlib import Path
from urllib.parse import unquote

WEBAPP_PREFIX = '/webapp'


def resolve_static_path(request_path, web_root):
    """Resolves `request_path` (expected to start with WEBAPP_PREFIX) to an
    existing file inside `web_root`.

    Returns None if the path doesn't start with WEBAPP_PREFIX, if it
    escapes web_root (via plain or URL-encoded `..` segments - checked by
    resolving the final path and verifying containment, not by
    string-matching `..`, since encoded or normalized traversal sequences
    can slip past a naive string check), or if it doesn't point at an
    existing file.
    """
    if not request_path.startswith(WEBAPP_PREFIX):
        return None

    remainder = unquote(request_path[len(WEBAPP_PREFIX):]).lstrip('/')
    if remainder == '':
        remainder = 'index.html'

    web_root_resolved = Path(web_root).resolve()
    candidate = (web_root_resolved / remainder).resolve()

    if not candidate.is_relative_to(web_root_resolved):
        return None
    if not candidate.is_file():
        return None
    return candidate


def guess_content_type(path):
    """Best-effort MIME type for `path`, falling back to a generic binary
    type for anything mimetypes doesn't recognize.
    """
    content_type, _ = mimetypes.guess_type(str(path))
    return content_type or 'application/octet-stream'
