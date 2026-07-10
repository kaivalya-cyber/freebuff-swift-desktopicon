#!/usr/bin/env bash
# ============================================================
# Freebuff CLI helper — manage ~/.freebuff/status.json
# ============================================================
#
# Usage:
#   ./freebuff.sh start "My task description"
#   ./freebuff.sh update 0.5 "optional new task description"
#   ./freebuff.sh done [--lines-added N] [--lines-removed N]
#   ./freebuff.sh cancel
#   ./freebuff.sh prompt "Your message here"
#   ./freebuff.sh status
#   ./freebuff.sh setup
#
# The JSON schema matches what the Swift menu bar app reads:
#
#   status.json (live session):
#   {
#     "status": "running|idle|done",
#     "task": "string",
#     "started_at": "ISO 8601",
#     "estimated_end_at": "ISO 8601 or null",
#     "progress": 0.0..1.0
#   }
#
#   history.json (completed sessions array):
#   [{
#     "id": "uuid",
#     "task": "string",
#     "started_at": "ISO 8601",
#     "ended_at": "ISO 8601",
#     "status": "completed|cancelled",
#     "lines_added": 0,
#     "lines_removed": 0
#   }]
#
#   prompt.json / response.json (chat bridge):
#   {"content": "string", "timestamp": "ISO 8601"}
# ============================================================

set -euo pipefail

FREEBUFF_DIR="${HOME}/.freebuff"
STATUS_FILE="${FREEBUFF_DIR}/status.json"
HISTORY_FILE="${FREEBUFF_DIR}/history.json"

# Ensure the directory exists
mkdir -p "${FREEBUFF_DIR}"

# ============================================================
# Python helper: all JSON generation uses python3 to avoid
# shell injection and heredoc JSON issues.
# ============================================================

PYTHON_JSON_HELPERS=$(cat <<'PYEOF'
import json, sys, os, uuid
from datetime import datetime, timezone, timedelta

STATUS_FILE = os.path.expanduser("~/.freebuff/status.json")
HISTORY_FILE = os.path.expanduser("~/.freebuff/history.json")

def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def read_status():
    if not os.path.exists(STATUS_FILE):
        return None
    with open(STATUS_FILE) as f:
        return json.load(f)

def write_status(data):
    with open(STATUS_FILE, "w") as f:
        json.dump(data, f, indent=2)

def read_history():
    if not os.path.exists(HISTORY_FILE):
        return []
    with open(HISTORY_FILE) as f:
        return json.load(f)

def write_history(data):
    with open(HISTORY_FILE, "w") as f:
        json.dump(data, f, indent=2)
PYEOF
)

# ============================================================
# Commands
# ============================================================

cmd_start() {
    local task="${1:-untitled task}"
    local est_minutes="${2:-7}"

    python3 -c "
${PYTHON_JSON_HELPERS}

existing = read_status()
if existing and existing.get('status') == 'running':
    import sys
    print('[Freebuff] Warning: a session is already running. Overwriting.', file=sys.stderr)

now = iso_now()
est_end = (datetime.now(timezone.utc) + timedelta(minutes=${est_minutes})).strftime('%Y-%m-%dT%H:%M:%SZ')

data = {
    'status': 'running',
    'task': sys.argv[1],
    'started_at': now,
    'estimated_end_at': est_end,
    'progress': 0.0
}
write_status(data)
print(f'[Freebuff] Session started: {sys.argv[1]}')
" "${task}"
}

cmd_update() {
    local progress="${1:-0.0}"
    local task_override="${2:-}"

    python3 -c "
${PYTHON_JSON_HELPERS}
import sys

data = read_status()
if data is None:
    print('[Freebuff] No active session. Use start first.', file=sys.stderr)
    sys.exit(1)

data['progress'] = float(sys.argv[1])
if len(sys.argv) > 2 and sys.argv[2]:
    data['task'] = sys.argv[2]

write_status(data)
print(f'[Freebuff] Progress: {sys.argv[1]}')
" "${progress}" "${task_override}"
}

cmd_done() {
    local lines_added=0
    local lines_removed=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lines-added) lines_added="$2"; shift 2 ;;
            --lines-removed) lines_removed="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    python3 -c "
${PYTHON_JSON_HELPERS}
import sys

data = read_status()
if data is None:
    print('[Freebuff] No active session to complete.', file=sys.stderr)
    sys.exit(1)

# Mark status as done
data['status'] = 'done'
data['progress'] = 1.0
data['estimated_end_at'] = None
write_status(data)

# Append to history
entry = {
    'id': str(uuid.uuid4()),
    'task': data.get('task', 'unknown'),
    'started_at': data.get('started_at', ''),
    'ended_at': iso_now(),
    'status': 'completed',
    'lines_added': int(sys.argv[1]),
    'lines_removed': int(sys.argv[2])
}

history = read_history()
history.append(entry)
write_history(history)

print(f'[Freebuff] Session complete: {entry[\"task\"]}')
" "${lines_added}" "${lines_removed}"
}

cmd_cancel() {
    python3 -c "
${PYTHON_JSON_HELPERS}
import sys

data = read_status()
if data is None:
    print('[Freebuff] No active session to cancel.', file=sys.stderr)
    sys.exit(1)

task = data.get('task', 'unknown')

# Mark status as done
data['status'] = 'done'
data['progress'] = 1.0
data['estimated_end_at'] = None
write_status(data)

# Append cancelled entry to history
entry = {
    'id': str(uuid.uuid4()),
    'task': task,
    'started_at': data.get('started_at', ''),
    'ended_at': iso_now(),
    'status': 'cancelled'
}

history = read_history()
history.append(entry)
write_history(history)

print(f'[Freebuff] Session cancelled: {task}')
"
}

cmd_status() {
    if [[ -f "${STATUS_FILE}" ]]; then
        echo "=== status.json ==="
        cat "${STATUS_FILE}"
    else
        echo "[Freebuff] No active session."
    fi

    if [[ -f "${HISTORY_FILE}" ]]; then
        echo ""
        echo "=== history.json (last 3 entries) ==="
        python3 -c "
${PYTHON_JSON_HELPERS}
history = read_history()
for entry in history[-3:]:
    print(json.dumps(entry, indent=2))
" 2>/dev/null || echo "(parse error)"
    else
        echo ""
        echo "[Freebuff] No history yet."
    fi
}

# ============================================================
# Prompt command: write a prompt and run the agent bridge
# ============================================================

cmd_prompt() {
    local text="${1:-}"

    if [[ -z "${text}" ]]; then
        echo "Usage: $0 prompt \"your message here\""
        exit 1
    fi

    # Write prompt.json (uses sys.argv to avoid shell injection)
    python3 -c "
import json, os, sys
from datetime import datetime, timezone

dir_path = os.path.expanduser('~/.freebuff')
os.makedirs(dir_path, exist_ok=True)

text = sys.argv[1]
prompt = {
    'content': text,
    'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
}

path = os.path.join(dir_path, 'prompt.json')
with open(path, 'w') as f:
    json.dump(prompt, f, indent=2)

preview = text[:60] + ('...' if len(text) > 60 else '')
print(f'[Freebuff] Prompt written: {preview}')
" "${text}"

    # Find and run the bridge script
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    BRIDGE_SCRIPT="${SCRIPT_DIR}/handle-prompt.py"

    if [[ -f "${BRIDGE_SCRIPT}" ]]; then
        echo "[Freebuff] Running agent bridge..."
        python3 "${BRIDGE_SCRIPT}"
    else
        echo "[Freebuff] Bridge script not found at ${BRIDGE_SCRIPT}"
        echo "[Freebuff] Run '$0 setup' to install it."
        exit 1
    fi
}

# ============================================================
# Setup command: install the bridge script to ~/.freebuff/
# ============================================================

cmd_setup() {
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    BRIDGE_SRC="${SCRIPT_DIR}/handle-prompt.py"
    BRIDGE_DST="${FREEBUFF_DIR}/handle-prompt.py"

    if [[ -f "${BRIDGE_SRC}" ]]; then
        cp "${BRIDGE_SRC}" "${BRIDGE_DST}"
        chmod +x "${BRIDGE_DST}"
        echo "[Freebuff] Installed agent bridge to ${BRIDGE_DST}"
    else
        echo "[Freebuff] Bridge script not found at ${BRIDGE_SRC}"
        echo "[Freebuff] Make sure you're running from the Freebuff project directory."
        exit 1
    fi
}

# ============================================================
# Dispatch
# ============================================================

case "${1:-}" in
    start)
        shift
        cmd_start "$@"
        ;;
    update)
        shift
        cmd_update "$@"
        ;;
    done)
        shift
        cmd_done "$@"
        ;;
    cancel)
        shift
        cmd_cancel "$@"
        ;;
    status)
        cmd_status
        ;;
    prompt)
        shift
        cmd_prompt "$@"
        ;;
    setup)
        cmd_setup
        ;;
    *)
        echo "Usage: $0 {start|update|done|cancel|status} [args...]"
        echo ""
        echo "Commands:"
        echo "  start \"task description\" [est_minutes]   Begin a new session"
        echo "  update <0.0-1.0> [\"new task\"]            Update progress"
        echo "  done [--lines-added N] [--lines-removed N]  Mark session complete"
        echo "  cancel                                 Cancel current session"
        echo "  prompt \"message\"                       Send a prompt through the agent bridge"
        echo "  status                                 Show current state"
        echo "  setup                                  Install the agent bridge script"
        exit 1
        ;;
esac
