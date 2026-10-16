// opentraffic.dev's static files answer range requests for media too, so videos can be scrubbed before
// they've finished loading (Cloudflare's static assets always send the whole file). Everything else is
// the static assets as they are.

interface Env {
  ASSETS: { fetch: (request: Request) => Promise<Response> }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const range = request.headers.get("range")
    if (request.method !== "GET" || !range) return env.ASSETS.fetch(request)
    const whole = await env.ASSETS.fetch(new Request(request.url, { method: "GET", headers: { accept: request.headers.get("accept") ?? "*/*" } }))
    if (whole.status !== 200) return whole
    const body = await whole.arrayBuffer()
    const size = body.byteLength
    const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim())
    let start = match && match[1] !== "" ? Number(match[1]) : NaN
    let end = match && match[2] !== "" ? Number(match[2]) : size - 1
    if (match && match[1] === "" && match[2] !== "") {
      start = Math.max(0, size - Number(match[2])) // the last n bytes
      end = size - 1
    }
    end = Math.min(end, size - 1)
    const headers = new Headers(whole.headers)
    headers.set("accept-ranges", "bytes")
    if (!Number.isFinite(start) || start > end || start >= size) {
      headers.set("content-range", `bytes */${size}`)
      return new Response(null, { status: 416, headers })
    }
    headers.set("content-range", `bytes ${start}-${end}/${size}`)
    headers.set("content-length", String(end - start + 1))
    return new Response(body.slice(start, end + 1), { status: 206, headers })
  },
}
