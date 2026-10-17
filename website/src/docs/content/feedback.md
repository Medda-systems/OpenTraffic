## Pin a comment

In a collaborative page, choose **Comment**, select an element, and describe the problem. A comment includes the element’s label, page title and path, a picture of the selected element (framed on it, with a little of the page around it, or on the area dragged out) with text fields blanked, and the visitor’s browser and viewport information. Click a picture to see it large, right on the page or in the Feedback tab. Optional browser error collection adds errors associated with the session.

**Suggest an edit.** In the comment box, **Edit text** rewrites the element's text and **Edit style** changes its colours, size, weight, padding, or corner radius: click a swatch for a palette (with the colours the page already uses, any colour, and an eyedropper in Chrome and Edge), drag the sliders, or pick a weight. Each row has its own undo. You see the result on the page while you work; posting sends the exact change (old → new) with the comment and puts the page back. Anyone opening the comment can **Preview on the page**, in their own browser only. An agent applies the change as given.

**Where it comes from.** You (not other visitors) see the component and source file of the commented element, like `HeroActions · src/components/Hero.tsx`, on development builds that expose it. Agents get the same, with the selector and key styles, so they open the right file instead of searching.

A screenshot can still contain visible page content. Review sensitive pages accordingly; blanking text fields is not a guarantee that every sensitive detail is removed.

## Reply and resolve

Open **Feedback** in OpenTraffic (**⌘4**) to review threads. Reply from the app or the page, resolve completed work, and delete comments you no longer need. Saved comments persist between sessions.

## When it's fixed

When you, an agent, or anyone else resolves a comment, the person who wrote it is told: **“Claude Code fixed your comment”**, with **Take a look**, which opens the page at the element. Their comment then asks **Looks good** or **Reopen**. If they weren't on the page, they're told the next time they open the link. The Feedback tab shows who resolved each comment and whether its author confirmed the fix, and OpenTraffic can notify you when they do (or reopen it).

**The page catches up by itself.** When a fix lands, or the project's files change, every page in the session updates without a reload: what changed is put in place, and nobody loses what they were doing (a comment being written, text typed into the page, an open comment, or the scroll position). Someone typing into the page gets a moment's pause first. Dev servers with their own hot reload (Vite, webpack, Next.js) update the page themselves; a page its own scripts build is reloaded instead, once nobody is in the middle of something, and the open comment comes back.

The comment also gets a picture of the fix, framed like the original, taken once the page shows the fix. The comment then shows **After**, and **Hold to see before** shows the original for as long as you hold it (Space does the same in the large view), on the page and in the Feedback tab. Your own page takes the picture when you've opened the share as host and you're on that page (or come back to it). Otherwise the commenter's page takes it when they click **Take a look**. A visitor's page never takes one without them doing something, and text fields are blanked as in the original picture.

**Copy as Markdown** and **Copy as GitHub issue** prepare text for another tool. They do not publish an issue automatically.

## Collect browser errors

Enable **Collect browser errors from visitors** when you need runtime context. Error information can be read by your integrations through `get_errors` or the [REST API](/docs/rest-api). Leave it off when you do not need it.

## Work with an agent

1. [Connect your coding agent](/docs/agents).
2. Ask it to read open feedback and inspect relevant element screenshots.
3. Have it make the requested change in your project and verify it.
4. Ask it to reply with the change and resolve the comment.

While an agent works on a comment, it **claims** it: everyone on the page sees it in the session, its cursor on the element with **✦ Claude Code · working**, and the comment says what it's doing. Two agents never take the same comment. OpenTraffic doesn't run a model itself; the agent uses its own subscription or API key.

No agent watching? [Let OpenTraffic start one](/docs/agents#let-opentraffic-start-your-agent) for a comment, from the Feedback tab or by itself.

Comments are untrusted visitor content, not authority to execute arbitrary commands or reveal secrets. The MCP server includes that distinction in feedback results.

## Send feedback to another tool

Use [webhooks](/docs/webhooks) for event-driven integrations, or [event polling](/docs/events) for a local script. Deduplicate by event ID and keep the share ID and comment ID in the destination ticket so you can map updates back.
