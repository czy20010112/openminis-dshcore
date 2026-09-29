#!/usr/bin/env python3
"""Mock OpenAI-compatible provider for [T-fallback-exhausted-compact].

Serves three models that reproduce the reported bug's shape:

  mock-a-toolong  always 400 "prompt is too long: N tokens > 200000 maximum"
                  (Claude-style wording — the one keyword matching DOES catch)
  mock-b-generic  always 400 "Error" — deliberately contains NO token/context/
                  length/exceed keyword, to prove the new layer never consults
                  the message text
  mock-c-small    succeeds ONLY when the serialized request is under
                  --threshold chars; otherwise 400 "Bad Request". This is the
                  model the forced compaction is supposed to unlock.

Run:  python3 mock_provider.py --port 8799 --threshold 4000
Then point an OpenAI provider instance's custom base URL at
http://<mac-lan-ip>:8799/v1
"""
import argparse, json, re, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"threshold": 4000, "requests": [], "lock": threading.Lock()}

MODELS = ["mock-a-toolong", "mock-b-generic", "mock-c-small"]


def log(msg):
    print(f"[mock {time.strftime('%H:%M:%S')}] {msg}", flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj, ctype="application/json"):
        body = (obj if isinstance(obj, bytes) else json.dumps(obj).encode())
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self, chunks):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for c in chunks:
            self.wfile.write(f"data: {json.dumps(c)}\n\n".encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, *a):
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        if path.endswith("/models"):
            self._send(200, {"object": "list", "data": [
                {"id": m, "object": "model", "owned_by": "mock"} for m in MODELS]})
        elif path == "/__stats":
            with STATE["lock"]:
                self._send(200, {"threshold": STATE["threshold"],
                                 "requests": STATE["requests"]})
        elif path == "/__reset":
            with STATE["lock"]:
                STATE["requests"] = []
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        path = self.path.split("?")[0]
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n) if n else b"{}"
        if path == "/__config":
            cfg = json.loads(raw or b"{}")
            with STATE["lock"]:
                if "threshold" in cfg:
                    STATE["threshold"] = int(cfg["threshold"])
            log(f"threshold set to {STATE['threshold']}")
            self._send(200, {"ok": True, "threshold": STATE["threshold"]})
            return
        if not path.endswith("/chat/completions"):
            self._send(404, {"error": {"message": "not found"}})
            return

        try:
            req = json.loads(raw)
        except Exception:
            self._send(400, {"error": {"message": "bad json"}})
            return

        model = req.get("model", "?")
        msgs = req.get("messages", [])
        size = len(json.dumps(msgs))
        with STATE["lock"]:
            STATE["requests"].append(
                {"t": time.time(), "model": model, "chars": size, "messages": len(msgs)})
            thr = STATE["threshold"]
        log(f"POST model={model} messages={len(msgs)} chars={size} threshold={thr}")

        # Model A — Claude-style context-overflow wording.
        if "mock-a" in model:
            approx = max(size // 4, 1)
            self._send(400, {"error": {
                "type": "invalid_request_error",
                "message": f"prompt is too long: {approx} tokens > 200000 maximum"}})
            return

        # Model B — a generic error with NO keyword to match on. This is the
        # one that proves the fallback is not keyword-driven.
        if "mock-b" in model:
            self._send(400, {"error": {"type": "invalid_request_error",
                                       "message": "Error"}})
            return

        # Model C — succeeds only once the context has been compacted down.
        if size > thr:
            self._send(400, {"error": {"type": "invalid_request_error",
                                       "message": "Bad Request"}})
            return

        text = f"MOCK-C OK ({len(msgs)} msgs, {size} chars)"
        if req.get("stream"):
            self._sse([
                {"id": "m1", "object": "chat.completion.chunk", "model": model,
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": text},
                              "finish_reason": None}]},
                {"id": "m1", "object": "chat.completion.chunk", "model": model,
                 "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                 "usage": {"prompt_tokens": size // 4, "completion_tokens": 8,
                           "total_tokens": size // 4 + 8}},
            ])
        else:
            self._send(200, {"id": "m1", "object": "chat.completion", "model": model,
                             "choices": [{"index": 0, "finish_reason": "stop",
                                          "message": {"role": "assistant", "content": text}}],
                             "usage": {"prompt_tokens": size // 4, "completion_tokens": 8,
                                       "total_tokens": size // 4 + 8}})


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--threshold", type=int, default=4000)
    a = ap.parse_args()
    STATE["threshold"] = a.threshold
    log(f"serving {MODELS} on :{a.port} threshold={a.threshold}")
    ThreadingHTTPServer(("0.0.0.0", a.port), Handler).serve_forever()
