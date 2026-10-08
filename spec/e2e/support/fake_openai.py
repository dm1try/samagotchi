# Fake OpenAI-compatible server for the web e2e suite (spec/e2e) and smoke runs. Mode is read per request from
# <dir>/mode (ok|400|401|429|500|503_then_script|json_503_then_script|json_400|malformed|stream_error|stream_error_always|stall|empty|script|forward).
# script: a multi-iteration turn from <dir>/script.json (see scripts/turn.json next to this file): the
# request's tool results since the last user message pick the iteration; each streams its "thinking"
# (reasoning_content), "text" (content) word by word ("delay" s apart, default 0.12) and its "tools" as
# native tool_calls deltas, so the worker (api: openai) runs real tools. "hold" seconds wait before an
# iteration's first chunk (a stable mid-turn moment). With "steer_keeps_count": true a user message right after a
# tool result (steering merged mid-turn, a plugin's nudge) doesn't restart the count.
# With "nudge_counts": true a system message after the
# last user message (an empty-answer retry's nudge) counts as a step too, so an empty iteration can be followed by
# an answer. An iteration's "thinking_file" (a path relative to scripts/, its leading "#" header lines dropped)
# streams in place of "thinking", "repeat" times over (default 1), and "chunk_chars" streams N chars per chunk
# instead of word by word (the script's "delay" still applies): a long looping thinking (loop-guard's watch).
# An iteration with "error": N answers HTTP N ({"error": {"message": "boom"}}) instead: a turn that fails after its
# tool steps (scripts/failed_after_steps.json).
# "branches" pick another iteration list by the first user message (a delegated child's task; see _script), or with
# "when_last" by the last one (a queued turn's prompt).
# /v1/models lists "fake-script" (or serves <dir>/models.json when there is one, e.g. with
# "architecture": {"input_modalities": ["text"]} for a text-only model);
# no upstream needed.
# 503_then_script: one 503 with Retry-After: 3 (a provider retry the UIs show), then flips to script.
# json_503_then_script: a 200 whose whole body is a plain JSON 503 error (OpenRouter's "503 inside a 200", no SSE
# framing), then flips to script. json_400: a 200 whose body is a plain JSON 400 error, every time.
# empty: a 200 stream whose only delta is content "" with finish_reason stop (nemotron's empty answer).
# stall: a 200 that sends only OpenRouter's keep-alive comments (every 0.3 s) until the client hangs up or 600 s pass,
# the shape of a queued free model (checks the first-token limit).
# stream_error: a 200 whose first SSE event is OpenRouter's upstream-failure shape
# (comment + {"choices":[],"error":{code 503}}), then flips to forward; _always keeps failing. "forward" proxies to the
# real llama.cpp at the third argument (default below; unreachable answers 502); "none" there means no upstream: what would be forwarded
# answers 404, as a chat host without /props does (the e2e suite, which must not reach a LAN server: an
# unreachable one stalls the worker's /props probes). Every request line + body is appended to <dir>/requests.log.
import http.server, json, os, sys, urllib.error, urllib.request
SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts")
PORT = int(sys.argv[1]); DIR = sys.argv[2]; UPSTREAM = sys.argv[3] if len(sys.argv) > 3 else "http://192.168.1.29:8081"
def mode():
    try: return open(os.path.join(DIR, "mode")).read().strip()
    except OSError: return "forward"
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _log(self, body):
        with open(os.path.join(DIR, "requests.log"), "a") as f:
            f.write(json.dumps({"m": self.command, "p": self.path, "auth": self.headers.get("Authorization"), "mode": mode(), "body": body.decode("utf-8", "replace")}) + "\n")
    def _send(self, code, body, ctype="application/json", extra=None):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(data)
    def _handle(self):
        body = self._body(); self._log(body); m = mode()
        if m == "script" and self.path.endswith("/models"):
            listed = os.path.join(DIR, "models.json")
            if os.path.exists(listed): return self._send(200, open(listed).read())
            return self._send(200, json.dumps({"data": [{"id": "fake-script"}]}))
        # A scripted turn's /props probe gets the no-props answer at once
        # (an OpenAI-only host), not the script's held reply.
        if m == "script" and self.path.split("?")[0] == "/props":
            return self._send(404, json.dumps({"error": {"message": "no /props (fake, script mode)"}}))
        if m == "script":
            return self._script(body)
        if m == "forward" or self.path.endswith("/models") or self.path.split("?")[0] == "/props":
            return self._forward(body)
        if m == "400": return self._send(400, json.dumps({"error": {"code": 400, "message": "the request exceeds the available context size, try increasing it", "type": "exceed_context_size_error"}}))
        if m == "401": return self._send(401, json.dumps({"error": {"message": "Invalid API key", "type": "authentication_error"}}))
        if m == "429":
            open(os.path.join(DIR, "mode"), "w").write("forward")
            return self._send(429, json.dumps({"error": {"message": "rate limited"}}), extra={"Retry-After": "2"})
        if m == "500": return self._send(500, json.dumps({"error": {"message": "boom"}}))
        if m == "503_then_script":
            open(os.path.join(DIR, "mode"), "w").write("script")
            return self._send(503, json.dumps({"error": {"message": "overloaded"}}), extra={"Retry-After": "3"})
        if m == "json_503_then_script":
            open(os.path.join(DIR, "mode"), "w").write("script")
            return self._send(200, json.dumps({"error": {"code": 503, "message": "The model is overloaded (fake), try again"}}))
        if m == "json_400": return self._send(200, json.dumps({"error": {"code": 400, "message": "fake-script is not a valid model ID"}}))
        if m == "malformed": return self._send(200, "{not json", )
        if m in ("stream_error", "stream_error_always"):
            if m == "stream_error": open(os.path.join(DIR, "mode"), "w").write("forward")
            err = {"choices": [], "error": {"code": 503, "message": "Provider returned error", "metadata": {"raw": "upstream overloaded (fake)", "provider_name": "FakeUp"}}}
            return self._send(200, ": OPENROUTER PROCESSING\n\ndata: " + json.dumps(err) + "\n\n", ctype="text/event-stream")
        if m == "empty":
            chunk = {"id": "x", "object": "chat.completion.chunk", "model": "fake-empty", "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}]}
            done = {"id": "x", "object": "chat.completion.chunk", "model": "fake-empty", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 10, "completion_tokens": 0, "total_tokens": 10}}
            return self._send(200, "data: " + json.dumps(chunk) + "\n\ndata: " + json.dumps(done) + "\n\ndata: [DONE]\n\n", ctype="text/event-stream")
        if m == "stall":
            import time
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            try:
                for _ in range(2000):
                    c = b": OPENROUTER PROCESSING\n\n"
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(c), c)); self.wfile.flush(); time.sleep(0.3)
                self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        return self._forward(body)
    def _script(self, body):
        import time, re
        script = json.load(open(os.path.join(DIR, "script.json")))
        messages = json.loads(body or b"{}").get("messages") or []
        # Tool results since the last user message: one per call the worker ran this turn.
        done = 0
        keeps = bool(script.get("steer_keeps_count")); nudges = bool(script.get("nudge_counts")); prev = None; seen_user = False
        for msg in messages:
            if msg.get("role") == "user" and not (keeps and prev in ("tool", "user")): done = 0; seen_user = True
            elif msg.get("role") == "tool": done += 1
            elif msg.get("role") == "system" and nudges and seen_user: done += 1
            prev = msg.get("role")
        its = script["iterations"]
        # "branches": [{"when": TEXT, "iterations": [...]}]: a session whose first user message holds TEXT (a
        # delegated child's task) runs its own iterations, so a parent and its child share one script.
        first_user = next((str(msg.get("content") or "") for msg in messages if msg.get("role") == "user"), "")
        # "when_last" picks by the last user message instead (a queued turn's prompt; an image prompt's content is
        # a parts list, matched as its JSON).
        user_msgs = [msg for msg in messages if msg.get("role") == "user"]
        last_user = json.dumps(user_msgs[-1].get("content")) if user_msgs else ""
        for branch in script.get("branches") or []:
            if (branch.get("when") and branch["when"] in first_user) or (branch.get("when_last") and branch["when_last"] in last_user):
                its = branch["iterations"]
                break
        it = its[min(done, len(its) - 1)]
        if it.get("error"): return self._send(int(it["error"]), json.dumps({"error": {"message": "boom"}}))
        delay = float(script.get("delay", 0.12))
        time.sleep(float(it.get("hold", 0)))
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        def w(obj):
            c = ("data: " + json.dumps(obj) + "\n\n").encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(c), c)); self.wfile.flush()
        ch = lambda d, f=None: {"id": "x", "object": "chat.completion.chunk", "model": "fake-script", "choices": [{"index": 0, "delta": d, "finish_reason": f}]}
        thinking = it.get("thinking") or ""
        if it.get("thinking_file"):
            lines = open(os.path.join(SCRIPTS, it["thinking_file"])).read().split("\n")
            while lines and lines[0].startswith("#"): lines.pop(0)
            thinking = "\n".join(lines)
        thinking = thinking * int(it.get("repeat", 1))
        size = int(it.get("chunk_chars") or 0)
        try:
            for text, field in ((thinking, "reasoning_content"), (it.get("text") or "", "content")):
                pieces = [text[i:i + size] for i in range(0, len(text), size)] if size else re.findall(r"\S+\s*|\s+", text)
                for piece in pieces:
                    w(ch({field: piece})); time.sleep(delay)
            tools = it.get("tools") or []
            for i, tool in enumerate(tools):
                w(ch({"tool_calls": [{"index": i, "id": "call_%d_%d" % (done, i), "type": "function",
                                      "function": {"name": tool["name"], "arguments": json.dumps(tool.get("arguments") or {})}}]}))
            w(ch({}, "tool_calls" if tools else "stop"))
            w({"id": "x", "object": "chat.completion.chunk", "model": "fake-script", "choices": [],
               "usage": {"prompt_tokens": 100 + 50 * done, "completion_tokens": 20, "total_tokens": 120 + 50 * done}})
            c = b"data: [DONE]\n\n"; self.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(c), c)); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
    def _forward(self, body):
        if UPSTREAM == "none": return self._send(404, json.dumps({"error": {"message": "no upstream (fake)"}}))
        req = urllib.request.Request(UPSTREAM + self.path, data=body if self.command == "POST" else None, method=self.command)
        for k in ("Content-Type", "Authorization"):
            if self.headers.get(k): req.add_header(k, self.headers[k])
        try:
            # A socket timeout (connect, or a gap between reads), not a whole-response limit: a slow prompt on the
            # real upstream still streams, but a dead host fails in 2 min instead of 10.
            resp = urllib.request.urlopen(req, timeout=120)
        except urllib.error.HTTPError as e:
            return self._send(e.code, e.read())
        except (urllib.error.URLError, OSError) as e:
            # Unreachable / refused / timed out upstream: a clear 502 instead of a dropped connection and a traceback.
            reason = getattr(e, "reason", e)
            return self._send(502, json.dumps({"error": {"message": "fake upstream %s unreachable: %s" % (UPSTREAM, reason)}}))
        self.send_response(resp.status)
        ctype = resp.headers.get("Content-Type", "application/json")
        self.send_header("Content-Type", ctype); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        while True:
            chunk = resp.read1(65536) if hasattr(resp, "read1") else resp.read(65536)
            if not chunk: break
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk)); self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
    do_GET = _handle; do_POST = _handle
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
