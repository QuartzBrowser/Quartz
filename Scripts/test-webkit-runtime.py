#!/usr/bin/env python3
"""Run an app's isolated WebKit rendering and loopback HTTP smoke checks."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import uuid


def run_smoke(executable, working_directory, timeout, fixture_url=None):
    arguments = [str(executable), "--quartz-webkit-smoke-test"]
    if fixture_url is not None:
        arguments += ["--quartz-webkit-smoke-url", fixture_url]
    mode = "loopback HTTP" if fixture_url else "offline rendering"
    print(f"Running {mode} smoke check: {executable}", flush=True)
    # Test the packaged loader paths, without development-shell dyld overrides.
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("DYLD_", "__XPC_DYLD_"))}
    try:
        result = subprocess.run(arguments, cwd=working_directory, env=environment,
                                capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        for output in (error.stdout, error.stderr):
            if output:
                print(output.decode(errors="replace") if isinstance(output, bytes) else output, end="")
        raise RuntimeError(f"{mode} smoke timed out after {timeout:g} seconds") from error
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)
    if result.returncode:
        raise RuntimeError(f"{mode} smoke exited with status {result.returncode}")
    if "WebKit smoke test passed:" not in result.stdout:
        raise RuntimeError(f"{mode} smoke exited without confirming rendering and JavaScript")


def check_runtime(executable, timeout):
    with tempfile.TemporaryDirectory(prefix="quartz-webkit-runtime-") as working_directory:
        run_smoke(executable, working_directory, timeout)
        request_path = f"/quartz-webkit-smoke/{uuid.uuid4().hex}"
        response_sent = threading.Event()
        body = b"<!doctype html><html><body><h1 id='probe'>Quartz engine</h1></body></html>"

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def setup(self):
                super().setup()
                self.connection.settimeout(5)

            def do_GET(self):
                if self.path != request_path:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                response_sent.set()

            def log_message(self, format, *arguments):
                pass

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            fixture_url = f"http://127.0.0.1:{server.server_port}{request_path}"
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
            thread.start()
            try:
                run_smoke(executable, working_directory, timeout, fixture_url)
                if not response_sent.is_set():
                    raise RuntimeError("The app passed rendering without requesting the loopback HTTP fixture")
                print("WebKit network smoke passed: received fixture GET, returned HTTP 200, rendered HTML and ran JavaScript.",
                      flush=True)
            finally:
                server.shutdown()
                thread.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path, help="packaged app executable (Quartz.app/Contents/MacOS/Quartz)")
    parser.add_argument("--timeout", type=float, default=60, help="timeout in seconds for each app invocation (default: 60)")
    arguments = parser.parse_args()
    executable = arguments.executable.resolve()
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error(f"not an executable: {executable}")
    if not math.isfinite(arguments.timeout) or arguments.timeout <= 0:
        parser.error("--timeout must be a positive finite number")
    try:
        check_runtime(executable, arguments.timeout)
    except (OSError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
