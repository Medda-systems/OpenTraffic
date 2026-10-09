// Demo dev servers for OpenTraffic captures: Orbit's site, API, and docs.
//   node servers.mjs [port ...]   (all three when no ports are given)
import http from "node:http"
import fs from "node:fs"

const favicon = fs.readFileSync(new URL("./favicon.png", import.meta.url))
const site = fs.readFileSync(new URL("./orbit.html", import.meta.url), "utf8")
const page = (title, body) => `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title><link rel="icon" href="/favicon.ico"><style>body{font:16px/1.5 system-ui;margin:60px auto;max-width:720px;color:#1f1147}h1{font-size:40px}</style></head><body>${body}</body></html>`
const pages = {
  5175: site,
  3002: page("Orbit API", "<h1>Orbit API</h1><p>GET /v1/launches · GET /v1/teams</p>"),
  4400: page("Orbit Docs", "<h1>Orbit Docs</h1><p>Plan launches with your whole team.</p>"),
}
const only = process.argv.slice(2).map(Number)
for (const [port, html] of Object.entries(pages)) {
  if (only.length && !only.includes(Number(port))) continue
  http.createServer((req, res) => {
    if (req.url.startsWith("/favicon")) { res.writeHead(200, { "content-type": "image/png" }); return res.end(favicon) }
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" }); res.end(html)
  }).listen(Number(port), "127.0.0.1")
}
console.log("demo servers up")
