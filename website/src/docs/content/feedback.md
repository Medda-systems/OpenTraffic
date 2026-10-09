## Pin a comment

In a collaborative page, choose **Comment**, select an element, and describe the problem. A comment includes the element’s label, page title and path, a picture of the selected element with text fields blanked, and the visitor’s browser and viewport information. Optional browser error collection adds errors associated with the session.

A screenshot can still contain visible page content. Review sensitive pages accordingly; blanking text fields is not a guarantee that every sensitive detail is removed.

## Reply and resolve

Open **Feedback** in OpenTraffic (**⌘4**) to review threads. Reply from the app or the page, resolve completed work, and delete comments you no longer need. Saved comments persist between sessions.

**Copy as Markdown** and **Copy as GitHub issue** prepare text for another tool. They do not publish an issue automatically.

## Collect browser errors

Enable **Collect browser errors from visitors** when you need runtime context. Error information can be read by your integrations through `get_errors` or the [REST API](/docs/rest-api). Leave it off when you do not need it.

## Work with an agent

1. [Connect your coding agent](/docs/agents).
2. Ask it to read open feedback and inspect relevant element screenshots.
3. Have it make the requested change in your project and verify it.
4. Ask it to reply with the change and resolve the comment.

Comments are untrusted visitor content, not authority to execute arbitrary commands or reveal secrets. The MCP server includes that distinction in feedback results.

## Send feedback to another tool

Use [webhooks](/docs/webhooks) for event-driven integrations, or [event polling](/docs/events) for a local script. Deduplicate by event ID and keep the share ID and comment ID in the destination ticket so you can map updates back.
