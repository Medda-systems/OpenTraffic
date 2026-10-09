## Configure a destination

In **Settings → Integrations → Webhooks**, add a URL (http or https), the events to send (none = all) and a
secret. Each event is POSTed as JSON (the same `Event` object as above) with:

- `X-OpenTraffic-Event`: the event type
- `X-OpenTraffic-Delivery`: the event id (the same on retries, so you can ignore duplicates)
- `X-OpenTraffic-Timestamp`: when this attempt was sent, in unix seconds
- `X-OpenTraffic-Signature`: `sha256=<hex HMAC-SHA256 of "<timestamp>.<raw body>", keyed with the secret>`

Answer with any 2xx status. Errors and other statuses are retried after 1, 5 and 25 seconds; each attempt
times out after 10 seconds and gets a fresh timestamp. Redirects aren't followed: a 3xx counts as a failed
delivery. Always check the signature against the timestamp and raw body before parsing it, and reject
timestamps more than a few minutes old to stop replays.

Node:

```js
import crypto from "node:crypto";
import http from "node:http";

const secret = process.env.OPENTRAFFIC_WEBHOOK_SECRET;

http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    const body = Buffer.concat(chunks);
    const timestamp = req.headers["x-opentraffic-timestamp"] ?? "";
    const expected = Buffer.from("sha256=" + crypto.createHmac("sha256", secret).update(`${timestamp}.`).update(body).digest("hex"));
    const given = Buffer.from(req.headers["x-opentraffic-signature"] ?? "");
    const fresh = Math.abs(Date.now() / 1000 - Number(timestamp)) < 300;
    if (!fresh || given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) {
      res.writeHead(401).end();
      return;
    }
    const event = JSON.parse(body);
    console.log(event.type, event.share.name, event.comment?.text ?? "");
    res.writeHead(204).end();
  });
}).listen(8787);
```

Python:

```python
import hashlib, hmac, json, os, time
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = os.environ["OPENTRAFFIC_WEBHOOK_SECRET"].encode()

class Hook(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        timestamp = self.headers.get("X-OpenTraffic-Timestamp", "")
        expected = "sha256=" + hmac.new(SECRET, timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()
        fresh = timestamp.isdigit() and abs(time.time() - int(timestamp)) < 300
        if not fresh or not hmac.compare_digest(expected, self.headers.get("X-OpenTraffic-Signature", "")):
            self.send_response(401)
            self.end_headers()
            return
        event = json.loads(body)
        print(event["type"], event["share"]["name"], (event.get("comment") or {}).get("text", ""))
        self.send_response(204)
        self.end_headers()

HTTPServer(("127.0.0.1", 8787), Hook).serve_forever()
```

## Delivery guarantees

Treat delivery as best effort with retries, not durable storage. Use `X-OpenTraffic-Delivery` to deduplicate repeated attempts. Reconcile against the REST API after downtime. Prefer HTTPS for destinations outside your Mac and keep the signing secret out of client-side code.
