#!/usr/bin/env python3
"""Поддельный Bot API для интеграционного теста.

Отвечает как Telegram и пишет журнал запросов: GET /_log. Первый getUpdates
отдаёт два нажатия «проверить» — из своего чата (1001) и из чужого (999);
бот должен отреагировать только на первое. Тела POST uclient шлёт чанками,
поэтому их и разбираем.
"""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = []
UPDATES = [
    {"update_id": 100, "message": {"message_id": 1, "chat": {"id": 999}, "text": "/check"}},
    {"update_id": 101, "callback_query": {"id": "cb1", "data": "check",
                                          "message": {"message_id": 2, "chat": {"id": 1001}}}},
]


class Handler(BaseHTTPRequestHandler):
    def read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", ""):
            data = b""
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def reply(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/_log":
            return self.reply(LOG)
        self.reply({"ok": False, "error_code": 404, "description": "Not Found"}, 404)

    def do_POST(self):
        token, method = self.path.split("/")[1], self.path.rsplit("/", 1)[-1]
        payload = json.loads(self.read_body() or b"{}")
        LOG.append({"t": time.time(), "token": token, "method": method, "payload": payload,
                    "chunked": "chunked" in self.headers.get("Transfer-Encoding", "")})
        if method == "getUpdates":
            pending = [u for u in UPDATES if u["update_id"] >= payload.get("offset", 0)]
            if not pending:
                # Настоящий Telegram держал бы запрос до timeout секунд.
                time.sleep(3)
            return self.reply({"ok": True, "result": pending})
        if method == "sendMessage":
            return self.reply({"ok": True, "result": {"message_id": len(LOG)}})
        return self.reply({"ok": True, "result": True})

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8081), Handler).serve_forever()
