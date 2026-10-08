# Security

Please report vulnerabilities privately through GitHub's **Report a vulnerability** button on this repository's Security tab, rather than in a public issue. Include what an attacker needs (for example, only a share's public link, or code running on the same Mac) and the steps to reproduce.

OpenTraffic's main trust boundaries:

- **Visitors to a share's public link:** they can reach the shared server, the collaboration hub, and the `/__opentraffic/` routes, and nothing else on the Mac.
- **Web pages in the user's browser:** they must not be able to use the local API on `127.0.0.1:47777`, or publish anything without the user confirming it.
- **Other apps on the Mac:** they need the API token for the local API. `opentraffic://` links that share or start something ask the user first.
