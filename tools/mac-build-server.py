#!/usr/bin/env python3
"""mac-build-server — run an sbc-deploy Bazel build on this Mac and stream the
logs back over HTTP so a remote helper (e.g. Claude in a Linux container) can
drive cross-build iteration without a Nix host of its own.

Why: cross-building the aarch64-linux image (`--cross`, FUG-86) only reproduces
on a machine with `nix` — i.e. this Mac. This server exposes exactly that build
behind a curl-able, streaming endpoint so logs (including `nix build
--show-trace`) come straight back to whoever hit it.

USAGE (on the Mac, from the repo root, in a shell where `nix` and `bazel` are on
PATH):

    python3 tools/mac-build-server.py            # binds 0.0.0.0:8099, prints URL+token

Then from anywhere on the LAN:

    curl -N "http://<mac-lan-ip>:8099/build?token=<token>"

`-N` (curl --no-buffer) streams the log live. The default build is the cross,
no-write image build with `--show-trace`; override per request:

    # just eval + trace (fast, for chasing eval errors):
    curl -N "http://<ip>:8099/build?token=T&nixargs=--show-trace&preargs=--no-write --cross"
    # a native (builder-dispatched) build instead:
    curl -N "http://<ip>:8099/build?token=T&preargs=--no-write --builder <spec>"
    # a different target:
    curl -N "http://<ip>:8099/build?token=T&target=//examples/hello-sbc:hello.image_sd_base"

Query params (all optional):
    token    shared secret (also accepted as header `X-Build-Token`)
    target   Bazel label (default //examples/hello-sbc:hello.image_sd)
    preargs  space-separated args before the nix `--` (default "--no-write --cross")
    nixargs  space-separated args forwarded to `nix` after `--` (default "--show-trace")

There is also a `/run` endpoint (same token) that streams back an arbitrary shell
command on the Mac — handy for diagnostics:

    curl -N "http://<ip>:8099/run?token=<token>&cmd=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' 'nix config show | grep builders')"

Same caveat as /build: this executes commands on your machine; keep it on a
trusted LAN and stop the server when you're done.

Security: this runs Bazel on your machine on request. It is gated by a token and
intended for a trusted LAN only. Stop it (Ctrl-C) when you're done. It refuses to
run more than one build at a time (returns 409 while busy).
"""

import os
import shlex
import socket
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# --- config (env-overridable) ------------------------------------------------
PORT = int(os.environ.get("BUILD_SERVER_PORT", "8099"))
TOKEN = os.environ.get("BUILD_SERVER_TOKEN") or os.urandom(8).hex()
DEFAULT_TARGET = "//examples/hello-sbc:hello.image_sd"
DEFAULT_PREARGS = "--no-write --cross"
DEFAULT_NIXARGS = "--show-trace"


def repo_root() -> str:
    """Repo root: $BUILD_SERVER_REPO, else the git toplevel of this script."""
    env = os.environ.get("BUILD_SERVER_REPO")
    if env:
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        out = subprocess.check_output(
            ["git", "-C", here, "rev-parse", "--show-toplevel"], text=True
        ).strip()
        if out:
            return out
    except Exception:
        pass
    return os.path.dirname(here)  # tools/ -> repo root


REPO = repo_root()

# One build at a time. HTTP is threaded so a second request gets a clean 409
# instead of silently queueing behind a multi-hour kernel compile.
_build_lock = threading.Lock()


def lan_ips():
    ips = set()
    try:
        # Common macOS interfaces; ignore failures (interface may be down).
        for iface in ("en0", "en1", "en2"):
            try:
                ip = subprocess.check_output(
                    ["ipconfig", "getifaddr", iface], text=True, stderr=subprocess.DEVNULL
                ).strip()
                if ip:
                    ips.add(ip)
            except Exception:
                pass
    except Exception:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    return sorted(ips)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Quieter default logging (one line per request is enough).
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _authed(self, qs) -> bool:
        tok = self.headers.get("X-Build-Token") or (qs.get("token", [""])[0])
        return tok == TOKEN

    def _chunk_headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

    def _write_chunk(self, data: bytes):
        # HTTP/1.1 chunked framing so curl -N streams each line as it arrives.
        self.wfile.write(b"%X\r\n" % len(data))
        self.wfile.write(data)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def _end_chunks(self):
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path in ("/", "/help"):
            body = (__doc__ or "").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path not in ("/build", "/run"):
            self.send_error(404, "try /build, /run, or /help")
            return

        if not self._authed(qs):
            self.send_error(401, "missing or bad token (query ?token= or header X-Build-Token)")
            return

        if not _build_lock.acquire(blocking=False):
            self.send_error(409, "a command is already running; try again when it finishes")
            return

        try:
            if parsed.path == "/build":
                self._run_build(qs)
            else:
                self._run_shell(qs)
        finally:
            _build_lock.release()

    # POST behaves the same as GET (handy for bodies/automation).
    do_POST = do_GET

    def _stream(self, cmd, shell=False):
        """Run cmd (list, or string if shell=True) from REPO, streaming
        combined stdout/stderr back as chunked output. Returns nothing."""
        proc = None
        try:
            proc = subprocess.Popen(
                cmd,
                cwd=REPO,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
                text=True,
                env=os.environ.copy(),
                shell=shell,
            )
            for line in proc.stdout:
                self._write_chunk(line.encode("utf-8", "replace"))
            proc.wait()
            self._write_chunk(("\n==> exit code: %d\n" % proc.returncode).encode())
        except BrokenPipeError:
            if proc and proc.poll() is None:
                proc.kill()
            return
        except Exception as e:
            try:
                self._write_chunk(("\n==> server error: %r\n" % e).encode())
            except Exception:
                pass
        finally:
            self._end_chunks()

    def _run_shell(self, qs):
        """/run?cmd=... — run an arbitrary shell command on the Mac and stream
        it back. Same token gate as /build. Runs via `bash -c` with the server's
        environment (so nix/bazel are on PATH), cwd = repo root."""
        cmd = qs.get("cmd", [""])[0]
        if not cmd:
            self._chunk_headers()
            self._write_chunk(b"==> no cmd= given\n")
            self._end_chunks()
            return
        self._chunk_headers()
        self._write_chunk(("==> repo: %s\n" % REPO).encode())
        self._write_chunk(("==> run:  %s\n\n" % cmd).encode())
        self._stream(["bash", "-c", cmd])

    def _run_build(self, qs):
        target = qs.get("target", [DEFAULT_TARGET])[0]
        preargs = shlex.split(qs.get("preargs", [DEFAULT_PREARGS])[0])
        nixargs = shlex.split(qs.get("nixargs", [DEFAULT_NIXARGS])[0])

        cmd = ["bazel", "run", target, "--", *preargs]
        if nixargs:
            cmd += ["--", *nixargs]

        self._chunk_headers()
        self._write_chunk(("==> repo: %s\n" % REPO).encode())
        self._write_chunk(("==> cmd:  %s\n\n" % " ".join(shlex.quote(c) for c in cmd)).encode())
        self._stream(cmd)


def main():
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("=" * 72)
    print("sbc-deploy mac-build-server")
    print("  repo : %s" % REPO)
    print("  port : %d" % PORT)
    print("  token: %s" % TOKEN)
    print("  reachable at:")
    for ip in lan_ips() or ["<this-mac-lan-ip>"]:
        print("    curl -N \"http://%s:%d/build?token=%s\"" % (ip, PORT, TOKEN))
    print("  (default build: bazel run %s -- %s -- %s)" % (DEFAULT_TARGET, DEFAULT_PREARGS, DEFAULT_NIXARGS))
    print("  Ctrl-C to stop.")
    print("=" * 72)
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping.")
        httpd.shutdown()


if __name__ == "__main__":
    main()
