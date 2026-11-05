#!/usr/bin/env python3
"""The web site as the snapshot harness serves it: nothing cached,
WebAssembly and JavaScript by their own types, and a backlog for the dozen
runtime modules the page asks for at once (a reset one leaves it blank with
no error). The standard library alone. snapshots.py serves it so from a
thread; CI's blue-ios serves it so on a Mac slot beside the iOS lease's
simulator (tools/ci/blue_ios_lease.sh):

  serve_site.py <directory> <host> <port>
"""
import functools, http.server, sys, threading

def server(directory, host, port):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def end_headers(self):
            self.send_header("Cache-Control", "no-store"); super().end_headers()
        def log_message(self, *args): pass
        extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm", ".js": "text/javascript"}
    # A backlog past socketserver's 5.
    class Server(http.server.ThreadingHTTPServer):
        request_queue_size = 128
    return Server((host, port), functools.partial(Quiet, directory=directory))

def serve(directory, host, port):
    """The site served from a thread of its own; the server, to shut down."""
    running = server(directory, host, port)
    threading.Thread(target=running.serve_forever, daemon=True).start()
    return running

if __name__ == "__main__":
    server(sys.argv[1], sys.argv[2], int(sys.argv[3])).serve_forever()
