#!/usr/bin/python3
"""
fetch-usage.py — write coding-assistant rate-limit usage to a file LidCode reads.

Reads the Anthropic OAuth credential for each configured Claude account from the
macOS keychain using /usr/bin/security (no TCC prompt required), polls the
Anthropic usage endpoint, reads each configured Codex profile's locally-reported
rate-limit snapshot, and writes a small JSON file to
/tmp/warp-monitor-usage.json.

No access token, refresh token, or credential blob is ever written to the output
file, any log, or any pushed payload. Only utilisation percentages, reset
timestamps, a severity label, account status, and the account activity marker
leave this script.

Install:   Script/install-usage-agent.sh
Runs as:   ~/Library/LaunchAgents/com.warp-monitor.fetch-usage.plist
Output:    /tmp/warp-monitor-usage.json
Errors:    /tmp/warp-monitor-usage-error.txt


Why this file is more than "GET a URL"
======================================

Two failure modes made the panel show "needs login" or "error" for accounts that
were, in fact, perfectly signed in. Both are handled here rather than in Swift,
because both are about *obtaining the reading* rather than displaying it.

1. Expired access tokens (`refresh_access_token`)
   -----------------------------------------------
   Claude Code's access tokens are short-lived and Claude Code refreshes them
   whenever it runs. An account you have not opened for a while therefore has a
   dead access token sitting in the keychain, the usage endpoint answers 401,
   and the panel says "needs login" — for an account whose login is fine. The
   refresh token in the same keychain entry is all that is needed to fix it, so
   this script uses it.

   The delicate part is that an OAuth refresh *may* return a new refresh token,
   and if it does, the old one is dead the moment we use it. Claude Code is
   holding that old one. So:

     - if the server returns the same refresh token, nothing is written to the
       keychain at all; the new access token goes in our own private cache and
       Claude Code is completely undisturbed;
     - if the server rotated it, the whole credential is written back to the
       keychain, because at that point *not* writing it back is what breaks the
       login.

   The write-back is verified by reading it straight back. If it did not land,
   that is recorded in the error file, since the user needs to know to run
   `claude /login` for that account.

2. Transient failures blanking good data (`load_last_good` / `carry_forward`)
   ---------------------------------------------------------------------------
   A dropped wifi connection, a sleeping Mac, or a five-second API blip used to
   replace a perfectly good reading with status "error", and the panel showed a
   dash for the next five minutes. Usage percentages do not change quickly, and
   a five-minute-old number is far more useful than no number. Each successful
   read is therefore remembered, and a failed one falls back to the last good
   value, stamped with when it was actually taken and flagged as carried so the
   panel can say "from 6m ago" rather than implying it is current.

   The carry-forward is capped (`CARRY_MAX_AGE_SECONDS`): past that, a stale
   rate-limit number is worse than an honest "unavailable", because the window
   it describes has probably reset.


Account key derivation
======================
Claude Code stores credentials in the macOS keychain under a service name
computed as:

    service = "Claude Code-credentials" + suffix

where suffix is:
  - "" when CLAUDE_SECURESTORAGE_CONFIG_DIR is unset (the default account)
  - "-" + sha256(NFC(config_dir)).hexdigest()[:8] when the env var is set

This script replicates that derivation for each account listed in ACCOUNTS so
the mapping is self-documenting and survives a future rename of the config dir.
"""

import hashlib
import json
import os
import ssl
import subprocess
import sys
import time
import unicodedata
import urllib.request
import urllib.error
from datetime import datetime, timezone

OUTPUT_PATH = "/tmp/warp-monitor-usage.json"
TMP_PATH    = "/tmp/warp-monitor-usage.json.tmp"
ERROR_PATH  = "/tmp/warp-monitor-usage-error.txt"

# Durable, so a reboot (which clears /tmp) does not also lose the fallback data
# and the refreshed tokens. Same directory LidCode already owns, mode 0700.
STATE_DIR       = os.path.expanduser("~/.lidcode")
LAST_GOOD_PATH  = os.path.join(STATE_DIR, "usage-last-good.json")
TOKEN_CACHE_PATH = os.path.join(STATE_DIR, "usage-token-cache.json")

API_URL         = "https://api.anthropic.com/api/oauth/usage"
TOKEN_URL       = "https://console.anthropic.com/v1/oauth/token"
# Claude Code's public OAuth client id. Not a secret — it identifies the app, and
# the refresh grant is authorised by the refresh token, not by this value.
OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TIMEOUT_SECONDS = 10

# Treat a token as expired this far ahead of its stated expiry, so a token that
# dies mid-request is refreshed before the request rather than after a 401.
EXPIRY_MARGIN_SECONDS = 120

# Beyond this, a carried-forward reading describes a window that has likely
# reset, so it stops being better than saying nothing.
CARRY_MAX_AGE_SECONDS = 6 * 3600

# One retry for genuinely transient network trouble, so a single dropped packet
# does not cost the whole five-minute cycle.
NETWORK_ATTEMPTS = 2
NETWORK_BACKOFF_SECONDS = 2

# Each entry: (key, label, config_dir_or_None)
# "config_dir" is the value that would be in CLAUDE_SECURESTORAGE_CONFIG_DIR.
# None means the default account — no suffix, no env var needed.
# Optional compatibility collector. The app itself collects natively; this script
# uses the same user-owned profiles when explicitly installed from source.
def configured_profiles():
    path = os.path.join(STATE_DIR, "ai-profiles.json")
    if not os.path.exists(path):
        return [
            {"id": "default-claude", "provider": "claude", "name": "Claude", "directory": ""},
            {"id": "default-codex", "provider": "codex", "name": "Codex", "directory": ""},
        ]
    with open(path, encoding="utf-8") as source:
        return json.load(source)

PROFILES = [p for p in configured_profiles() if p.get("isEnabled", True)]
ACCOUNTS = [
    (p["id"], p["name"], os.path.expanduser(p["directory"]) if p.get("directory") else None)
    for p in PROFILES if p["provider"] == "claude"
]
CODEX_ACCOUNTS = [
    (p["id"], p["name"], os.path.join(os.path.expanduser(p.get("directory") or "~/.codex"), "sessions"))
    for p in PROFILES if p["provider"] == "codex"
]
MAX_CODEX_SESSION_FILES = 32
CODEX_TAIL_BYTES = 1_048_576


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

class KeychainMissing(RuntimeError):
    """The keychain entry is absent — this account is genuinely not signed in."""


class TokenExpired(RuntimeError):
    """The API returned HTTP 401. The access token needs refreshing."""


class RefreshFailed(RuntimeError):
    """The refresh grant itself failed. Only a real re-login can fix this."""


# ---------------------------------------------------------------------------
# Keychain service name derivation
# ---------------------------------------------------------------------------

def _keychain_service(config_dir):
    """
    Return the keychain service name Claude Code uses for the given config dir.

    Replicates Claude Code's own derivation:
      - config_dir is None  -> "Claude Code-credentials"
      - config_dir set      -> "Claude Code-credentials-" + sha256(NFC(dir))[:8]

    The NFC normalisation step is deliberate: Claude Code normalises the path
    before hashing so the suffix is stable across different Unicode normal
    forms of the same path string.
    """
    base = "Claude Code-credentials"
    if config_dir is None:
        return base
    normalised = unicodedata.normalize("NFC", config_dir)
    suffix = hashlib.sha256(normalised.encode()).hexdigest()[:8]
    return f"{base}-{suffix}"


# ---------------------------------------------------------------------------
# Small on-disk state, mode 0600
# ---------------------------------------------------------------------------

def _ensure_state_dir():
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    except OSError:
        pass


def _read_json(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_json_private(path, data):
    """Atomic write, owner-read-write only. Never raises."""
    _ensure_state_dir()
    tmp = path + ".tmp"
    try:
        # Create with 0600 from the start rather than chmod-ing after: between
        # the two there is a moment where the file exists and is world-readable,
        # and a token cache is exactly the wrong file to leave in that state.
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


# ---------------------------------------------------------------------------
# Error log helpers
# ---------------------------------------------------------------------------

def write_error(msg: str) -> None:
    ts = datetime.now(timezone.utc).isoformat()
    try:
        with open(ERROR_PATH, "w") as f:
            f.write(f"{ts} {msg}\n")
    except OSError:
        pass


def clear_error() -> None:
    """Remove the error log so a recovered state does not look broken forever."""
    try:
        os.remove(ERROR_PATH)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def clamp(value: float, lo: float = 0.0, hi: float = 100.0) -> float:
    return max(lo, min(hi, float(value)))


def _now_epoch() -> float:
    return time.time()


def _as_epoch_seconds(value):
    """
    Claude Code writes `expiresAt` in epoch milliseconds. Accept seconds too, so
    a future change of unit degrades to a slightly eager refresh rather than a
    token treated as valid for the next fifty thousand years.
    """
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number / 1000.0 if number > 1e11 else number


def _ssl_context():
    """
    Build an SSL context that trusts the macOS system certificate store.

    /usr/bin/python3 (the Python shipped with the Xcode Command Line Tools) does
    not auto-load system roots via urllib, because its bundled openssl looks for
    certs at a path that only exists in a full Python.org installation.
    /etc/ssl/cert.pem is a symlink to the macOS system root bundle and is
    present on every macOS 12+ machine — use it explicitly.
    """
    cafile = "/etc/ssl/cert.pem"
    ctx = ssl.create_default_context(cafile=cafile if os.path.exists(cafile) else None)
    if not os.path.exists(cafile):
        ctx.set_default_verify_paths()
    return ctx


def _post_json(url: str, payload: dict, headers: dict) -> dict:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    for name, value in headers.items():
        req.add_header(name, value)
    with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS, context=_ssl_context()) as resp:
        return json.loads(resp.read())


# ---------------------------------------------------------------------------
# Keychain read and write
# ---------------------------------------------------------------------------

def read_credential(service: str) -> dict:
    """
    Return the full parsed credential blob Claude Code stores for `service`.
    Uses /usr/bin/security so no TCC prompt fires.
    """
    try:
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", service, "-w"],
            capture_output=True, text=True, timeout=10,
        )
    except Exception as exc:
        raise RuntimeError(f"security command failed: {exc}") from exc

    if result.returncode != 0:
        # Non-zero means the entry does not exist — normal for an account that
        # has never been authenticated on this machine.
        raise KeychainMissing(f"security returned {result.returncode}")

    raw = result.stdout.strip()
    if not raw:
        raise RuntimeError("security returned empty output")

    try:
        creds = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"unexpected keychain credential shape: {exc}") from exc
    if not isinstance(creds, dict) or "claudeAiOauth" not in creds:
        raise RuntimeError("keychain credential has no claudeAiOauth section")
    return creds


def _keychain_account(service: str):
    """
    The `acct` attribute of the keychain item, needed to update it in place.
    Returned as None when it cannot be parsed, which makes the caller skip the
    write-back rather than create a second, competing item.
    """
    try:
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", service],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return None
    if result.returncode != 0:
        return None
    # Line looks like:  "acct"<blob>="princewagan"
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith('"acct"') and '="' in line:
            return line.split('="', 1)[1].rstrip('"')
    return None


def write_credential(service: str, credential: dict) -> bool:
    """
    Update the keychain item in place and verify it landed.

    Only ever called when a refresh rotated the refresh token, because that is
    the only case where leaving the keychain alone is the destructive option —
    Claude Code would be holding a refresh token we have already spent.

    Note on `-w <value>`: `security` takes the secret as an argument, so it is
    briefly visible in this user's own process list. There is no stdin form of
    this command. The exposure is same-user only and lasts milliseconds, and any
    process that could read it could equally read the keychain item directly.
    """
    account = _keychain_account(service)
    if not account:
        return False
    blob = json.dumps(credential, separators=(",", ":"))
    try:
        result = subprocess.run(
            ["/usr/bin/security", "add-generic-password",
             "-U", "-a", account, "-s", service, "-w", blob],
            capture_output=True, text=True, timeout=15,
        )
    except Exception:
        return False
    if result.returncode != 0:
        return False

    # Read it straight back. A write that reported success but did not land is
    # the one outcome that silently costs the user their login, so it is checked
    # rather than assumed.
    try:
        check = read_credential(service)
    except RuntimeError:
        return False
    return check.get("claudeAiOauth", {}).get("refreshToken") == \
        credential.get("claudeAiOauth", {}).get("refreshToken")


# ---------------------------------------------------------------------------
# Token refresh
# ---------------------------------------------------------------------------

def refresh_access_token(service: str, credential: dict):
    """
    Exchange the stored refresh token for a fresh access token.

    Returns (access_token, expires_at_epoch_seconds).
    Raises RefreshFailed when the grant is rejected — only a real login fixes that.

    See the module docstring for why the keychain is written back only when the
    refresh token actually rotated.
    """
    oauth = credential.get("claudeAiOauth", {})
    old_refresh = oauth.get("refreshToken")
    if not isinstance(old_refresh, str) or not old_refresh:
        raise RefreshFailed("no refresh token stored")

    try:
        data = _post_json(TOKEN_URL, {
            "grant_type": "refresh_token",
            "refresh_token": old_refresh,
            "client_id": OAUTH_CLIENT_ID,
        }, {})
    except urllib.error.HTTPError as exc:
        raise RefreshFailed(f"refresh rejected: HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RefreshFailed(f"refresh network error: {exc.reason}") from exc
    except (ValueError, OSError) as exc:
        raise RefreshFailed(f"refresh response unreadable: {exc}") from exc

    access = data.get("access_token")
    if not isinstance(access, str) or not access:
        raise RefreshFailed("refresh response carried no access token")

    expires_in = data.get("expires_in")
    try:
        expires_at = _now_epoch() + float(expires_in)
    except (TypeError, ValueError):
        expires_at = _now_epoch() + 3600.0

    new_refresh = data.get("refresh_token") or old_refresh

    # Our own copy, always. This is what makes the common case zero-risk: with a
    # non-rotating refresh token the keychain is never touched at all.
    cache = _read_json(TOKEN_CACHE_PATH)
    cache[service] = {"access_token": access, "expires_at": expires_at}
    _write_json_private(TOKEN_CACHE_PATH, cache)

    if new_refresh != old_refresh:
        # Rotated. The token Claude Code holds is now dead, so the new one has to
        # reach the keychain or that account is logged out at its next refresh.
        updated = dict(credential)
        updated_oauth = dict(oauth)
        updated_oauth["accessToken"] = access
        updated_oauth["refreshToken"] = new_refresh
        updated_oauth["expiresAt"] = int(expires_at * 1000)
        updated["claudeAiOauth"] = updated_oauth
        if not write_credential(service, updated):
            # Deliberately loud: the refresh token has already been spent, so
            # this account will need `claude /login` and the user cannot guess that.
            raise RefreshFailed(
                "refresh token rotated but could not be saved to the keychain — "
                "run `claude /login` for this account")

    return access, expires_at


def access_token_for(service: str, credential: dict, force_refresh: bool = False):
    """
    The token to call the usage API with.

    Order of preference: a still-valid token from the keychain, then a still-valid
    token we refreshed earlier, then a fresh refresh. `force_refresh` skips the
    first two, and is used after the API has told us a token is dead.
    """
    oauth = credential.get("claudeAiOauth", {})

    if not force_refresh:
        token = oauth.get("accessToken")
        expires_at = _as_epoch_seconds(oauth.get("expiresAt"))
        if isinstance(token, str) and token:
            # No expiry recorded: trust it, and let a 401 drive the refresh.
            if expires_at is None or expires_at - EXPIRY_MARGIN_SECONDS > _now_epoch():
                return token

        cached = _read_json(TOKEN_CACHE_PATH).get(service) or {}
        cached_token = cached.get("access_token")
        cached_expiry = cached.get("expires_at")
        if isinstance(cached_token, str) and cached_token and \
                isinstance(cached_expiry, (int, float)) and \
                cached_expiry - EXPIRY_MARGIN_SECONDS > _now_epoch():
            return cached_token

    access, _ = refresh_access_token(service, credential)
    return access


# ---------------------------------------------------------------------------
# Usage API
# ---------------------------------------------------------------------------

def fetch_usage(token: str) -> dict:
    """
    GET the Anthropic OAuth usage endpoint. Retries once on a network error,
    because a single dropped connection should not cost a whole five-minute cycle.
    Raises TokenExpired on HTTP 401, RuntimeError on anything else.
    """
    req = urllib.request.Request(API_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
    })
    ctx = _ssl_context()

    last_error = None
    for attempt in range(NETWORK_ATTEMPTS):
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS, context=ctx) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"API returned HTTP {resp.status}")
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            # An HTTP status is a definitive answer, so it is never retried.
            if exc.code == 401:
                raise TokenExpired() from exc
            raise RuntimeError(f"API HTTP error {exc.code}: {exc.reason}") from exc
        except urllib.error.URLError as exc:
            last_error = RuntimeError(f"API network error: {exc.reason}")
        except json.JSONDecodeError as exc:
            last_error = RuntimeError(f"API response is not valid JSON: {exc}")
        if attempt + 1 < NETWORK_ATTEMPTS:
            time.sleep(NETWORK_BACKOFF_SECONDS)

    raise last_error if last_error else RuntimeError("API call failed")


def derive_severity(data: dict) -> str:
    """
    Inspect the limits[] array for active entries with a non-normal severity.
    Return the worst severity found, or "normal" if all active limits are normal.
    """
    severity_rank = {"critical": 2, "warning": 1, "normal": 0}
    worst, worst_rank = "normal", 0

    limits = data.get("limits", [])
    if not isinstance(limits, list):
        return "normal"

    for entry in limits:
        if not isinstance(entry, dict):
            continue
        if not entry.get("is_active", False):
            continue
        rank = severity_rank.get(entry.get("severity", "normal"), 0)
        if rank > worst_rank:
            worst, worst_rank = entry.get("severity", "normal"), rank
    return worst


# ---------------------------------------------------------------------------
# Per-account fetch
# ---------------------------------------------------------------------------

def fetch_account(key: str, label: str, config_dir, as_of: str) -> dict:
    """
    Attempt to fetch usage for a single account. Always returns a dict with at
    least {"key", "label", "status"}. Never raises.

    Status values:
      "ok"         — token obtained (refreshing first if needed) and API returned 200
      "signed_out" — keychain entry absent
      "expired"    — token dead and the refresh grant was rejected; needs a real login
      "error"      — anything else; carries a short "error" string, never a token
    """
    service = _keychain_service(config_dir)
    base = {
        "key": key,
        "label": label,
        "provider": "claude",
        "storage_dir": config_dir,
    }

    try:
        credential = read_credential(service)
    except KeychainMissing:
        return {**base, "status": "signed_out"}
    except RuntimeError as exc:
        return {**base, "status": "error", "error": str(exc)}

    # First attempt with whatever valid token we can find; on a 401, refresh and
    # try once more. The second pass is what turns a stale token — the common
    # cause of a spurious "needs login" — into a normal reading.
    data = None
    for force in (False, True):
        try:
            token = access_token_for(service, credential, force_refresh=force)
        except RefreshFailed as exc:
            return {**base, "status": "expired", "error": str(exc)}
        except RuntimeError as exc:
            return {**base, "status": "error", "error": str(exc)}

        try:
            data = fetch_usage(token)
            break
        except TokenExpired:
            if force:
                # Already refreshed and still refused — the grant is genuinely dead.
                return {**base, "status": "expired",
                        "error": "refreshed token still rejected"}
            continue
        except RuntimeError as exc:
            return {**base, "status": "error", "error": str(exc)}

    if data is None:
        return {**base, "status": "error", "error": "no usage data returned"}

    try:
        five = data["five_hour"]
        seven = data["seven_day"]
        result = {
            **base,
            "status":    "ok",
            "severity":  derive_severity(data),
            "as_of":     as_of,
            "five_hour": {
                "utilization": clamp(five["utilization"]),
                "resets_at":   str(five["resets_at"]),
            },
            "seven_day": {
                "utilization": clamp(seven["utilization"]),
                "resets_at":   str(seven["resets_at"]),
            },
        }
    except (KeyError, TypeError, ValueError) as exc:
        return {**base, "status": "error", "error": f"unexpected API response shape: {exc}"}

    return result


def _codex_reset_at(value) -> str:
    """Convert Codex's Unix reset timestamp into the JSON format LidCode reads."""
    if not isinstance(value, (int, float)):
        raise ValueError("reset timestamp missing")
    return datetime.fromtimestamp(value, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _codex_iso_timestamp(value):
    """Parse one Codex event timestamp into a UTC Unix timestamp."""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).timestamp()


def _codex_activity_iso(timestamp):
    """Format an activity timestamp for the usage JSON."""
    if timestamp is None:
        return None
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _codex_usage_from_event(event: dict):
    """Return the two windows from one Codex token-count event, or None."""
    payload = event.get("payload")
    if not isinstance(payload, dict) or payload.get("type") != "token_count":
        return None
    limits = payload.get("rate_limits")
    if not isinstance(limits, dict):
        return None
    primary, secondary = limits.get("primary"), limits.get("secondary")
    if not isinstance(primary, dict) or not isinstance(secondary, dict):
        return None
    try:
        return {
            "five_hour": {
                "utilization": clamp(float(primary["used_percent"])),
                "resets_at": _codex_reset_at(primary["resets_at"]),
            },
            "seven_day": {
                "utilization": clamp(float(secondary["used_percent"])),
                "resets_at": _codex_reset_at(secondary["resets_at"]),
            },
        }
    except (KeyError, TypeError, ValueError, OverflowError, OSError):
        return None


def _recent_codex_session_files(root: str) -> list:
    """Newest session logs first, bounded so a large history stays cheap to poll."""
    candidates = []
    try:
        for directory, _, names in os.walk(root):
            for name in names:
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(directory, name)
                try:
                    candidates.append((os.path.getmtime(path), path))
                except OSError:
                    continue
    except OSError:
        return []
    candidates.sort(reverse=True)
    return [path for _, path in candidates[:MAX_CODEX_SESSION_FILES]]


def _codex_session_start(path: str):
    """Read a session's start time, which is the best local login/use signal."""
    try:
        with open(path, "rb") as source:
            # Codex writes session_meta first. Keep this bounded so a malformed
            # or unexpectedly large header cannot make the five-minute poll slow.
            for _ in range(16):
                line = source.readline(64 * 1024)
                if not line:
                    break
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if event.get("type") == "session_meta":
                    return _codex_iso_timestamp(event.get("timestamp"))
    except OSError:
        return None
    return None


def _codex_profile_activity(sessions_dir: str):
    """Return the latest login/session activity for one Codex profile.

    Codex does not expose a cross-profile "current account" flag. The durable
    local signals are the auth file's `last_refresh` value (updated by
    login/refresh), its mtime as a fallback, and the session_meta timestamp
    (written when a CLI session starts). Taking the newer of these makes
    switching accounts visible without reading a token.
    """
    latest = None
    auth_path = os.path.join(os.path.dirname(sessions_dir), "auth.json")
    try:
        with open(auth_path, encoding="utf-8") as source:
            auth = json.load(source)
        latest = _codex_iso_timestamp(auth.get("last_refresh"))
    except (OSError, ValueError, TypeError):
        pass
    if latest is None:
        try:
            latest = os.path.getmtime(auth_path)
        except OSError:
            pass
    for path in _recent_codex_session_files(sessions_dir):
        started = _codex_session_start(path)
        if started is not None and (latest is None or started > latest):
            latest = started
    return latest


def _last_codex_usage(path: str):
    """Read the latest complete rate-limit event from the tail of one session."""
    try:
        with open(path, "rb") as source:
            source.seek(0, os.SEEK_END)
            size = source.tell()
            source.seek(max(0, size - CODEX_TAIL_BYTES))
            tail = source.read().decode("utf-8", errors="ignore")
    except OSError:
        return None

    # A partially written final JSONL record is normal while Codex is running;
    # reverse scanning lets us use the immediately preceding complete record.
    for line in reversed(tail.splitlines()):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        usage = _codex_usage_from_event(event)
        if usage is not None:
            return usage
    return None


def fetch_codex_account(key: str, label: str, sessions_dir: str, as_of: str) -> dict:
    """Read one Codex profile's most recent local rate-limit snapshot."""
    last_used_at = _codex_activity_iso(_codex_profile_activity(sessions_dir))
    base = {
        "key": key,
        "label": label,
        "provider": "codex",
        "is_active": False,
        "last_used_at": last_used_at,
        # This field is used only to identify Claude's active config directory.
        # Keeping it null for Codex preserves the public JSON shape while the
        # Swift reader uses `provider` to keep Codex rows out of that match.
        "storage_dir": None,
    }
    for path in _recent_codex_session_files(sessions_dir):
        usage = _last_codex_usage(path)
        if usage is not None:
            return {**base, "status": "ok", "severity": "normal", "as_of": as_of, **usage}
    return {**base, "status": "error", "error": "no Codex usage data found"}


# ---------------------------------------------------------------------------
# Last-good carry-forward
# ---------------------------------------------------------------------------

def load_last_good() -> dict:
    return _read_json(LAST_GOOD_PATH)


def save_last_good(store: dict, accounts: list) -> None:
    for acct in accounts:
        if acct.get("status") == "ok" and not acct.get("carried"):
            store[acct["key"]] = acct
    _write_json_private(LAST_GOOD_PATH, store)


def _age_seconds(iso_text) -> float:
    if not isinstance(iso_text, str):
        return float("inf")
    try:
        stamp = datetime.strptime(iso_text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return float("inf")
    return (datetime.now(timezone.utc) - stamp).total_seconds()


def carry_forward(result: dict, store: dict) -> dict:
    """
    Replace a failed reading with the last good one for the same account, flagged
    so the panel can say how old it is.

    A genuinely signed-out account is never carried: "signed_out" is a stable
    fact about the machine rather than a blip, and papering over it with an hour
    old percentage would hide the one state the user has to act on.
    """
    if result.get("status") == "ok":
        return result
    if result.get("status") == "signed_out":
        return result

    previous = store.get(result["key"])
    if not isinstance(previous, dict) or previous.get("status") != "ok":
        return result
    if _age_seconds(previous.get("as_of")) > CARRY_MAX_AGE_SECONDS:
        return result

    carried = dict(previous)
    # Keep the current account metadata even when only the numeric reading is
    # carried forward. This lets new fields (such as the provider marker and a
    # renamed display label) take effect immediately without waiting for a
    # successful poll.
    for field in ("key", "label", "provider", "storage_dir", "is_active", "last_used_at"):
        if field in result:
            carried[field] = result[field]
    carried["carried"] = True
    carried["degraded"] = result.get("status", "error")
    return carried


# ---------------------------------------------------------------------------
# Severity helpers for the top-level summary
# ---------------------------------------------------------------------------

_SEVERITY_RANK = {"critical": 2, "warning": 1, "normal": 0}


def _worst_severity(accounts: list) -> str:
    worst, worst_rank = "normal", 0
    for acct in accounts:
        if acct.get("status") != "ok":
            continue
        rank = _SEVERITY_RANK.get(acct.get("severity", "normal"), 0)
        if rank > worst_rank:
            worst, worst_rank = acct.get("severity", "normal"), rank
    return worst


def _best_ok_account(accounts: list):
    """The Claude account with the lowest five-hour utilisation, i.e. most headroom."""
    best, best_util = None, float("inf")
    for acct in accounts:
        # These top-level fields predate the account list and still drive the
        # Claude-only menu-bar fallback. CODEX must never become that fallback.
        if (acct.get("provider") == "codex" or acct.get("key") == "codex"
                or acct.get("status") != "ok"):
            continue
        util = acct.get("five_hour", {}).get("utilization", float("inf"))
        if util < best_util:
            best, best_util = acct, util
    return best


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    fetched_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    store = load_last_good()

    # One failure must never prevent the other accounts from being written.
    # The requested display order is stable: ADVO CLAUDE, PRINCE CLAUDE,
    # ADVO CODEX, PRINCE CODEX.
    accounts = []
    for key, label, config_dir in ACCOUNTS:
        result = fetch_account(key, label, config_dir, as_of=fetched_at)
        accounts.append(carry_forward(result, store))
    codex_results = []
    for key, label, sessions_dir in CODEX_ACCOUNTS:
        codex_results.append(fetch_codex_account(key, label, sessions_dir, as_of=fetched_at))

    # There is no global Codex account flag when two CODEX_HOME roots exist.
    # Mark the profile whose auth/session activity is newest; this mirrors the
    # account most recently used to log in or start the Codex CLI.
    def activity_value(result):
        return _codex_iso_timestamp(result.get("last_used_at"))

    active_codex = max(
        codex_results,
        key=lambda result: activity_value(result) if activity_value(result) is not None else float("-inf"),
        default=None,
    )
    active_key = (
        active_codex.get("key")
        if active_codex is not None and activity_value(active_codex) is not None
        else None
    )
    for result in codex_results:
        result["is_active"] = result.get("key") == active_key
        accounts.append(carry_forward(result, store))

    save_last_good(store, accounts)

    live_count = sum(1 for a in accounts if a.get("status") == "ok" and not a.get("carried"))
    shown_count = sum(1 for a in accounts if a.get("status") == "ok")

    output = {
        "fetched_at": fetched_at,
        "severity":   _worst_severity(accounts),
        "accounts":   accounts,
    }

    # Top-level five_hour/seven_day are the back-compat summary, taken from the
    # account with the most remaining headroom.
    best = _best_ok_account(accounts)
    if best is not None:
        output["five_hour"] = best["five_hour"]
        output["seven_day"] = best["seven_day"]

    try:
        fd = os.open(TMP_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(output, f, indent=2)
            f.write("\n")
        os.replace(TMP_PATH, OUTPUT_PATH)
    except OSError as exc:
        write_error(f"[fetch-usage] write error: {exc}")
        return 1

    # The error file describes whether this *run* worked, not whether the panel
    # has something to show — a carried-forward reading is still a degraded state
    # worth naming, even though the user can see numbers.
    if live_count == len(accounts):
        clear_error()
    else:
        detail = "; ".join(
            f"{a['label']}: " + (
                f"carried, {a.get('degraded', '?')}" if a.get("carried")
                else f"{a.get('status', '?')} {a.get('error', '')}".strip()
            )
            for a in accounts
            if a.get("status") != "ok" or a.get("carried")
        )
        write_error(f"[fetch-usage] {live_count}/{len(accounts)} accounts live: {detail}")

    # Exit non-zero only when there is genuinely nothing to show.
    return 0 if shown_count > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
