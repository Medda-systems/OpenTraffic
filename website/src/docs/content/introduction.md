OpenTraffic is a macOS menu bar app for sharing local web servers and reviewing them together. It manages the tunnel, checks the connection, and brings live feedback back to your Mac.

## Start here

1. [Install OpenTraffic](/docs/installation) on macOS 14 or later.
2. [Share your first server](/docs/quickstart) and send its URL to a teammate.
3. [Add live collaboration](/docs/collaboration) for cursors, comments, and follow mode.
4. [Connect a coding agent](/docs/agents) to work through feedback in your existing tools.

## How it works

Your browser or your teammate’s browser connects to a tunnel provider’s URL. The provider forwards the connection to your Mac, and OpenTraffic routes it to the local service you chose. Your Mac, OpenTraffic, the connector, and the local server need to remain running.

With collaboration enabled, a local proxy adds presence and feedback tools to HTML pages. Session coordination runs inside OpenTraffic. Visitors use a browser; they do not install OpenTraffic.

## Choose your path

| What you need | Start with |
| --- | --- |
| A disposable link with no account | [Cloudflare Quick Tunnels](/docs/cloudflare-quick) |
| A lasting address without an account | [OpenTunnel](/docs/opentunnel) |
| Access limited to your tailnet | [Tailscale](/docs/tailscale) |
| Request inspection and password protection | [ngrok](/docs/ngrok) |
| A hostname on your own domain | [Cloudflare custom domains](/docs/custom-domains) |
| Feedback in your agent or issue tracker | [MCP](/docs/mcp), [REST API](/docs/rest-api), [webhooks](/docs/webhooks) |

## A few useful terms

- **Local service:** the web server on your Mac, such as `http://localhost:5173`.
- **Share:** a saved configuration that connects a local service to a public or tailnet URL.
- **Connector:** the provider process that carries traffic between the provider and your Mac.
- **Origin:** another name for the local service a tunnel forwards to.
- **Session:** the people and feedback associated with a collaborative share.

## Documentation scope

These guides cover OpenTraffic 1.0.2. Features implemented after that release are explicitly marked **Unreleased**. Provider accounts, limits, and availability are controlled by their respective services; check the linked provider documentation when configuring an account.

For a task-focused guide, use the sidebar. For exact commands and request fields, use the Reference section. Search all guides with **⌘K** or **Ctrl+K**.
