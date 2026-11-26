"""Minimal in-memory stand-in for the GitHub git refs and workflow run APIs
used by the molecule lock jobs. Usage: python3 mock_github_api.py <port-file>

Token "readonly" gets 403 on writes, token "noactions" 403 on workflow runs.
Runs are in_progress unless set otherwise. Test helpers:
  POST /_test/held/<run>/<branch>  lock branch held by run <run>, attempt 1
  POST /_test/run/<run>/<status>   set the status of run <run>, attempt 1
"""

import hashlib
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
OBJECTS = {}
REFS = {}
RUNS = {}
PREFIX = "/repos/o/r/git/"


def new_sha(kind, payload):
    data = f"{kind}{time.time_ns()}{json.dumps(payload, sort_keys=True)}"
    return hashlib.sha1(data.encode()).hexdigest()


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length) or b"{}")

    def readonly(self):
        if self.headers.get("Authorization") == "Bearer readonly":
            self.reply(403, {"message": "Resource not accessible by integration"})
            return True
        return False

    def do_GET(self):
        path = self.path
        if path.startswith("/repos/o/r/actions/runs/"):
            if self.headers.get("Authorization") == "Bearer noactions":
                return self.reply(403, {"message": "Resource not accessible by integration"})
            run = path[len("/repos/o/r/actions/runs/"):].split("/")[0]
            with LOCK:
                status = RUNS.get(run, "in_progress")
            if status == "gone":
                return self.reply(404, {"message": "Not Found"})
            return self.reply(200, {"id": int(run), "status": status})
        with LOCK:
            if path.startswith(PREFIX + "ref/heads/"):
                ref = "refs/heads/" + path[len(PREFIX + "ref/heads/"):]
                if ref in REFS:
                    return self.reply(200, {"ref": ref, "object": {"sha": REFS[ref]}})
                return self.reply(404, {"message": "Not Found"})
            if path.startswith(PREFIX + "commits/"):
                sha = path[len(PREFIX + "commits/"):]
                if sha in OBJECTS:
                    return self.reply(200, OBJECTS[sha])
        self.reply(404, {"message": "Not Found"})

    def do_POST(self):
        path = self.path
        if path.startswith("/_test/held/"):
            run, branch = path[len("/_test/held/"):].split("/", 1)
            role, scenario = branch[len("molecule-lock/"):].split("/", 1)
            message = (f"Molecule lock held by https://github.example/o/r/actions/runs/{run}"
                       f"/attempts/1 {role}/{scenario} (00000000)")
            with LOCK:
                sha = new_sha("commit", branch)
                OBJECTS[sha] = {"sha": sha, "message": message,
                                "committer": {"date": iso(time.time() - 86400)}}
                REFS["refs/heads/" + branch] = sha
            return self.reply(201, {"sha": sha})
        if path.startswith("/_test/run/"):
            run, status = path[len("/_test/run/"):].split("/", 1)
            with LOCK:
                RUNS[run] = status
            return self.reply(201, {})
        if self.readonly():
            return
        body = self.body()
        with LOCK:
            if path == PREFIX + "trees":
                sha = new_sha("tree", body)
                OBJECTS[sha] = {"sha": sha, "tree": body["tree"]}
                return self.reply(201, {"sha": sha})
            if path == PREFIX + "commits":
                sha = new_sha("commit", body)
                OBJECTS[sha] = {"sha": sha, "message": body["message"],
                                "committer": {"date": iso(time.time())}}
                return self.reply(201, {"sha": sha})
            if path == PREFIX + "refs":
                if body["ref"] in REFS:
                    return self.reply(422, {"message": "Reference already exists"})
                REFS[body["ref"]] = body["sha"]
                return self.reply(201, {"ref": body["ref"], "object": {"sha": body["sha"]}})
        self.reply(404, {"message": "Not Found"})

    def do_DELETE(self):
        if self.readonly():
            return
        with LOCK:
            if self.path.startswith(PREFIX + "refs/heads/"):
                ref = "refs/heads/" + self.path[len(PREFIX + "refs/heads/"):]
                if REFS.pop(ref, None):
                    self.send_response(204)
                    self.end_headers()
                    return
        self.reply(422, {"message": "Reference does not exist"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
