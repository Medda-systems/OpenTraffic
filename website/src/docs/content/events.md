## Event stream

**Events** are kept in memory (the last 1000). `GET /v1/events` returns events with `seq >= since` (default 0:
everything kept); with `wait`, it holds the request until there is at least one or the time is up. Pass `next`
as `since` on the following call:

```sh
since=0
while true; do
  page=$(api "http://127.0.0.1:47777/v1/events?since=$since&wait=60")
  echo "$page" | jq -c '.events[] | {type, share: .share.name, comment: .comment.text}'
  since=$(echo "$page" | jq .next)
done
```

Event types: `share.started`, `share.stopped`, `session.joined`, `session.left`, `comment.created`,
`comment.updated` (also when a comment is resolved, confirmed, or reopened: see its `status`), `comment.deleted`,
`comment.claimed` (an app started working on it: `comment.claimedBy`), `comment.released` (it stopped without
resolving it, or its claim lapsed), `error.reported`, `control.requested` (a viewer of a Mac app share set to ask to
control asks for it: `viewer`), `build.started`, `build.failed` and `build.succeeded` (a shared Mac app is rebuilt
after its sources changed: `build`).

## Event object

Each event has a monotonically increasing `seq`, unique `id`, `type`, ISO 8601 `at`, and `share` reference (`id`, `name`, optional `publicURL`). Depending on type, it may include `comment`, `commentId`, `peer`, `error`, or `viewer` (`control.requested`: the viewer's `viewer` number, the `name` its page gave, and `since`; answer with `POST /v1/shares/{ref}/control`), or `build` (`build.*`: its `state`, the `message` with the compiler's first error when it failed, the build's `log` file and its `command`; viewers see the previous version until a build succeeds).

## Reconnect and deduplicate

Save `next` after processing a batch. Event history is limited to the last 1000 entries in memory, so it is not a durable queue. After an app restart or a long disconnection, reload shares and feedback, then start a new polling cycle. Deduplicate downstream actions by event ID.

The polling example uses the `api` helper from [REST API](/docs/rest-api) and requires `jq`.
