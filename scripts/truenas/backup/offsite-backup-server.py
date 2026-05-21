#!/usr/bin/env python3

import os
import pty
import select
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOST = "0.0.0.0"
PORT = 8787
VERSION = "1.0.0"
ENDPOINT = "/offsite-backup"
POLL_SECONDS = 1
READ_SIZE = 1024
MAX_HTTP_LINES = 5000
TRIM_MARKER = "[older output trimmed]"
STDOUT_EXCLUDE_PREFIXES = ("/tmp/restic-backup/", "[")

state_lock = threading.Lock()
state = {
    "lines": [""],
    "row": 0,
    "col": 0,
    "stdout_lines": [],
}


def build_raw_text():
    with state_lock:
        lines = list(state["lines"])
    return "\n".join(lines) + "\n"


def build_html():
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>offsite-backup v{VERSION}</title>
  <style>
    body {{ background: black; color: white; font-family: monospace; }}
    h1 {{ font-size: 1.2em; border-bottom: 1px solid #333; padding-bottom: 5px; }}
  </style>
</head>
<body>
<h1>offsite-backup v{VERSION}</h1>
<pre id="log">loading...</pre>
<script>
(function() {{
  const pre = document.getElementById('log');
  async function update() {{
    try {{
      const res = await fetch('{ENDPOINT}?raw=1', {{ cache: 'no-store' }});
      pre.textContent = await res.text();
    }} catch (err) {{
      pre.textContent = 'error: ' + err;
    }}
  }}
  update();
  setInterval(update, {POLL_SECONDS * 1000});
}})();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path != ENDPOINT:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"not found\n")
            return

        query = parse_qs(parsed.query)
        if "raw" in query:
            body = build_raw_text().encode("utf-8", errors="replace")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        body = build_html().encode("utf-8", errors="replace")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


def ensure_line(lines, row):
    while row >= len(lines):
        lines.append("")


def trim_http_lines(state_data):
    lines = state_data["lines"]
    overflow = len(lines) - MAX_HTTP_LINES
    if overflow <= 0:
        return
    del lines[:overflow]
    if lines:
        lines[0] = TRIM_MARKER
    else:
        lines.append(TRIM_MARKER)
    state_data["row"] = max(0, state_data["row"] - overflow)


def put_char(lines, row, col, ch):
    ensure_line(lines, row)
    line = lines[row]
    if col < len(line):
        line = line[:col] + ch + line[col + 1:]
    else:
        line = line + (" " * (col - len(line))) + ch
    lines[row] = line


def move_cursor(state_data, delta_row, delta_col):
    state_data["row"] = max(0, state_data["row"] + delta_row)
    state_data["col"] = max(0, state_data["col"] + delta_col)


def handle_erase_in_line(state_data, mode):
    lines = state_data["lines"]
    row = state_data["row"]
    col = state_data["col"]
    ensure_line(lines, row)
    line = lines[row]
    if mode == 2:
        lines[row] = ""
    elif mode == 1:
        lines[row] = (" " * col) + line[col:]
    else:
        lines[row] = line[:col]


def handle_erase_display(state_data, mode):
    if mode == 2:
        state_data["lines"] = [""]
        state_data["row"] = 0
        state_data["col"] = 0


def apply_csi(state_data, csi):
    if not csi:
        return
    final = csi[-1]
    params = csi[:-1]
    values = []
    if params:
        for part in params.split(";"):
            try:
                values.append(int(part) if part else 0)
            except ValueError:
                values.append(0)
    else:
        values = [0]

    value = values[0] if values else 0

    if final == "A":
        move_cursor(state_data, -max(1, value), 0)
    elif final == "B":
        move_cursor(state_data, max(1, value), 0)
    elif final == "C":
        move_cursor(state_data, 0, max(1, value))
    elif final == "D":
        move_cursor(state_data, 0, -max(1, value))
    elif final == "K":
        handle_erase_in_line(state_data, value)
    elif final == "J":
        handle_erase_display(state_data, value)


def process_chunk(state_data, chunk, parser_state):
    esc = parser_state["esc"]
    csi = parser_state["csi"]

    for ch in chunk:
        if esc:
            if csi is None:
                if ch == "[":
                    csi = ""
                else:
                    esc = False
            else:
                if "@" <= ch <= "~":
                    apply_csi(state_data, csi + ch)
                    esc = False
                    csi = None
                else:
                    csi += ch
            continue

        if ch == "\x1b":
            esc = True
            csi = None
            continue

        if ch == "\r":
            state_data["col"] = 0
            continue

        if ch == "\n":
            committed = state_data["lines"][state_data["row"]].rstrip()
            if not any(committed.startswith(p) for p in STDOUT_EXCLUDE_PREFIXES):
                state_data["stdout_lines"].append(committed)
            state_data["row"] += 1
            state_data["col"] = 0
            ensure_line(state_data["lines"], state_data["row"])
            continue

        if ch == "\b":
            state_data["col"] = max(0, state_data["col"] - 1)
            continue

        put_char(state_data["lines"], state_data["row"], state_data["col"], ch)
        state_data["col"] += 1

    parser_state["esc"] = esc
    parser_state["csi"] = csi
    trim_http_lines(state_data)


def run_backup(script_path, server):
    master_fd, slave_fd = pty.openpty()
    process = None

    try:
        try:
            process = subprocess.Popen(
                ["bash", script_path],
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                close_fds=True,
            )
        finally:
            os.close(slave_fd)

        parser_state = {"esc": False, "csi": None}
        while True:
            ready, _, _ = select.select([master_fd], [], [], 0.2)
            if ready:
                try:
                    data = os.read(master_fd, READ_SIZE)
                except OSError:
                    break
                if not data:
                    break
                chunk = data.decode("utf-8", errors="replace")
                with state_lock:
                    process_chunk(state, chunk, parser_state)
            if process.poll() is not None and not ready:
                break
    finally:
        os.close(master_fd)
        if process is not None:
            process.wait()

        with state_lock:
            stdout_lines = list(state["stdout_lines"])

        for line in stdout_lines:
            sys.stdout.write(line + "\n")
        sys.stdout.flush()

        server.shutdown()


def main():
    script_path = os.path.join(os.path.dirname(__file__), "offsite-backup.sh")
    if not os.path.exists(script_path):
        raise SystemExit(f"missing script: {script_path}")

    print(f"Starting offsite-backup-server v{VERSION} on {HOST}:{PORT}")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    backup_thread = threading.Thread(target=run_backup, args=(script_path, server), daemon=True)
    backup_thread.start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()