#!/usr/bin/env python3
"""本地 mock Tailscale API v2，用于离线验证 control.yml 的任务流。

启动后覆盖：GET/PUT acl、POST acl/validate、GET/POST users、DELETE users/{id}。
仅在 127.0.0.1:8765 监听，进程退出数据即清空。
"""
import json
import re
from http.server import BaseHTTPRequestHandler, HTTPServer

ACL = {"acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}]}
USERS = [
    {"id": "u1", "loginName": "existing@example.com", "role": "admin"},
    {"id": "u2", "loginName": "old@example.com", "role": "member"},
]


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("ETag", '"mock-etag-1"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.endswith("/acl"):
            # 远端返回“空 ACL”，保证与本地文件必然存在差异以触发 PUT
            self._json(200, {"acls": []})
        elif self.path.endswith("/users"):
            self._json(200, USERS)
        else:
            self._json(404, {"message": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if self.path.endswith("/acl/validate"):
            try:
                json.loads(body or b"{}")
                self._json(200, {"message": "", "errors": []})
            except json.JSONDecodeError as e:
                self._json(400, {"message": str(e)})
        elif self.path.endswith("/users"):
            payload = json.loads(body or b"{}")
            new = {"id": f"u{len(USERS) + 3}", "loginName": payload["email"],
                   "role": payload.get("role", "member")}
            USERS.append(new)
            print(f"[mock] created user {new['loginName']}")
            self._json(200, new)
        else:
            self._json(404, {"message": "not found"})

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if self.path.endswith("/acl"):
            if self.headers.get("If-Match") != '"mock-etag-1"':
                self._json(412, {"message": "etag mismatch"})
                return
            global ACL
            ACL = json.loads(body)
            print(f"[mock] acl updated: {len(ACL.get('acls', []))} rules")
            self._json(200, ACL)
        else:
            self._json(404, {"message": "not found"})

    def do_DELETE(self):
        m = re.fullmatch(r"/api/v2/tailnet/-/users/(\w+)", self.path)
        if m:
            uid = m.group(1)
            before = len(USERS)
            USERS[:] = [u for u in USERS if u["id"] != uid]
            if len(USERS) < before:
                print(f"[mock] deleted user id={uid}")
                self._json(200, {})
            else:
                self._json(404, {"message": "user not found"})
        else:
            self._json(404, {"message": "not found"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
