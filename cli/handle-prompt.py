#!/usr/bin/env python3
"""
Freebuff Agent Bridge — processes prompts from the menu bar chat
through the local Codebuff CLI and writes responses back.

Called by the Swift app when a user submits a prompt.

Reads:  ~/.freebuff/prompt.json   (written by Swift app)
         ~/.freebuff/config.json   (optional: project directory, timeout)
Writes: ~/.freebuff/response.json  (picked up by Swift app DispatchSource)

Usage:
  python3 handle-prompt.py [--cwd <project-dir>] [--timeout <seconds>]
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

FREEBUFF_DIR = os.path.expanduser("~/.freebuff")
PROMPT_FILE = os.path.join(FREEBUFF_DIR, "prompt.json")
RESPONSE_FILE = os.path.join(FREEBUFF_DIR, "response.json")
CONFIG_FILE = os.path.join(FREEBUFF_DIR, "config.json")


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_config() -> dict:
    """Load optional config: project directory, timeout."""
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE) as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def load_prompt() -> dict | None:
    """Read the latest prompt from prompt.json."""
    if not os.path.exists(PROMPT_FILE):
        return None
    try:
        with open(PROMPT_FILE) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def write_response(content: str, error: bool = False) -> None:
    """Write an agent response (or error) to response.json."""
    os.makedirs(FREEBUFF_DIR, exist_ok=True)

    prefix = "[Error] " if error else ""
    response = {
        "content": prefix + content,
        "timestamp": iso_now(),
    }
    with open(RESPONSE_FILE, "w") as f:
        json.dump(response, f, indent=2)


def find_project_dir() -> str:
    """
    Try to determine the project directory:
    1. From ~/.freebuff/config.json (project_dir key)
    2. From status.json (if a session is running, infer from task context)
    3. Fall back to current working directory
    """
    config = load_config()
    if "project_dir" in config:
        path = os.path.expanduser(config["project_dir"])
        if os.path.isdir(path):
            return path

    # Try reading the status — if there's an active session, use a reasonable default
    cwd = os.getcwd()
    if os.path.isdir(cwd):
        return cwd

    return os.path.expanduser("~")


def run_codebuff(prompt_text: str, project_dir: str, timeout: int = 300) -> tuple[str, bool]:
    """
    Run the Codebuff CLI with the given prompt.

    Uses `npx codebuff <prompt>` which passes the prompt as a
    positional argument. Codebuff processes it and exits.

    Returns (output_text, is_error).
    """
    try:
        result = subprocess.run(
            ["npx", "codebuff", prompt_text],
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=project_dir,
            env={**os.environ, "NO_COLOR": "1", "FORCE_COLOR": "0"},
        )

        # Combine stdout and stderr; prefer stdout if available
        output = result.stdout.strip()
        if not output and result.stderr.strip():
            output = result.stderr.strip()

        is_error = result.returncode != 0
        return output, is_error

    except subprocess.TimeoutExpired:
        return "Codebuff took too long to respond (timeout). Try a simpler prompt.", True
    except FileNotFoundError:
        return (
            "Codebuff CLI not found. Make sure Node.js is installed and "
            "`npx codebuff` works from your terminal. You may need to run "
            "`npm install -g codebuff` or ensure npx is in your PATH.",
            True,
        )
    except Exception as e:
        return f"Failed to run Codebuff: {e}", True


def main():
    # Parse optional args
    args = sys.argv[1:]
    project_dir = find_project_dir()
    timeout = 300

    i = 0
    while i < len(args):
        if args[i] == "--cwd" and i + 1 < len(args):
            project_dir = os.path.expanduser(args[i + 1])
            i += 2
        elif args[i] == "--timeout" and i + 1 < len(args):
            timeout = int(args[i + 1])
            i += 2
        else:
            i += 1

    # Load the prompt
    prompt_data = load_prompt()
    if not prompt_data:
        write_response("No prompt found. Type something in the chat first.", error=True)
        sys.exit(1)

    prompt_text = prompt_data.get("content", "").strip()
    if not prompt_text:
        write_response("Empty prompt.", error=True)
        sys.exit(1)

    # Truncate the prompt file so we don't re-process it
    # (write an empty placeholder to mark it as consumed)
    with open(PROMPT_FILE, "w") as f:
        json.dump({"content": "", "timestamp": iso_now(), "consumed": True}, f)

    # Run Codebuff
    output, is_error = run_codebuff(prompt_text, project_dir, timeout)

    # Post-process: strip ANSI codes and terminal noise
    import re
    # Strip ANSI escape sequences
    output = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", output)
    # Strip carriage returns
    output = output.replace("\r", "")
    # Trim
    output = output.strip()

    if not output:
        output = "(Codebuff produced no output. The prompt may have been empty or Codebuff may have encountered an issue.)"

    write_response(output, error=is_error)


if __name__ == "__main__":
    main()
