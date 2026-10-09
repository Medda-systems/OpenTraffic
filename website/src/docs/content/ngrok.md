## Setup and sharing

**New Tunnel → ngrok** (or **Share ▾ → Public with ngrok**) shares a local server through your ngrok account. OpenTraffic reuses the authtoken already in ngrok's own config (`ngrok config add-authtoken …`) and never edits that file; Settings → ngrok shows whether the CLI and authtoken are present. Leave the domain empty to use your account's domain (free accounts get one permanent `*.ngrok-free.dev` domain, which OpenTraffic remembers so the URL is shown while stopped), or enter a reserved domain.

Each agent gets its own private inspection port, so OpenTraffic's agents never collide with each other or with ngrok started in Terminal. ngrok tunnels have a **Requests** tab (⌘3): every request with method, path, status, and duration; headers and bodies (JSON pretty-printed) with Authorization, Cookie, and API-key values hidden until revealed; **Replay**; and **Copy as cURL** (secrets left out). The Traffic card shows ngrok's request counts and 2xx–5xx classes from recent requests.

The free plan serves one ngrok share at a time on its domain; OpenTraffic refuses a second one up front and names the share that's running, and explains ngrok's own errors (missing authtoken, domain already online, unreserved domain) in plain language. Browser visitors on the free plan see an ngrok notice before your site; API clients and webhooks don't. ngrok agents started outside OpenTraffic are listed read-only in Settings → ngrok.

## Next steps

See [Protected shares](/docs/protection), [Everyday sharing](/docs/sharing), and [Troubleshooting](/docs/troubleshooting).
