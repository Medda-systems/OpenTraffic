## Before you begin

Install [OpenTraffic](/docs/installation). The first time it opens, click **Install** next to Cloudflare in the setup assistant; this walkthrough uses Cloudflare's temporary URLs. (Already set up? It's in Settings → Cloudflare, or run `opentraffic install cloudflared`.)

Start your existing web app and check that its local URL opens in your browser. This guide uses `http://localhost:5173`; substitute the port your app actually uses.

## Share the server

1. Open OpenTraffic from Applications.
2. Click its menu bar icon and find your app under **Ready to Share**.
3. Choose **Share ▾ → Temporary URL**, or use **New Tunnel → Temporary URL** and enter your local URL.
4. Wait for the public URL and connection checks. New DNS names may need a short grace period.
5. Copy the URL and open it in a separate browser window. Send it to your teammate once your app loads.

You do not need a Cloudflare account for a temporary URL. Keep the local server and OpenTraffic running while someone uses the link.

![OpenTraffic’s menu bar with detected local servers and sharing controls](/docs/images/share.png)

## Review it together

Enable **Live collaboration** on the share. If it is already running, OpenTraffic asks before restarting it; a Quick Tunnel restart normally changes its URL. Open **Open as Host** for the host controls, and give teammates the public URL.

Use **Lead** to have visitors follow your page and scroll position. Ask them to use **Comment** to pin feedback to an element. Their comments appear in the app’s **Feedback** tab.

[Learn about collaboration and its limits](/docs/collaboration).

## Stop sharing

Click **Stop** on the Live card or in the main window. This stops the connector and keeps the saved share. **Remove** deletes the local saved entry; it does not delete a Cloudflare tunnel from your account.

> A temporary URL is public to anyone who has it. Use [Tailscale](/docs/tailscale) for private tailnet access or a [protected share](/docs/protection) when access control is needed.

## If the link does not work

- **Local service failed:** open the local URL directly and start or repair your app.
- **Host rejected:** use **Fix Host Header** or the framework configuration shown by OpenTraffic.
- **Starting:** allow DNS or certificate setup to finish, then recheck health.

See [Troubleshooting](/docs/troubleshooting) for the full checklist.
