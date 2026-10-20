# Mac app mirror protocol (v1)

How a shared Mac app's window reaches a browser. The **mirror server** (`MirrorServer`, one per
session) runs next to the real app on the host's Mac; the **viewer** (`macapp-viewer.html/.js/.css`)
runs in the browser. This page is the whole contract: the viewer can be written from it alone.
The Swift side of it is `Sources/OpenTrafficCore/MacApp/MirrorProtocol.swift` (`MirrorProtocol.*`),
tested in `Tests/OpenTrafficCoreTests/MacAppProtocolTests.swift`; change all three together.

## Origin and HTTP

The mirror server listens on a loopback port per session (`http://127.0.0.1:<port>`). In a share it is
the upstream of CollabProxy, so viewers reach it through the share URL with the collaboration overlay.

| Request | Answer |
| --- | --- |
| `GET /` | The viewer page (HTML, so CollabProxy injects `bridge.js` and `collab.js` into it like any page) |
| `GET /__opentraffic/macapp/viewer.js` | The viewer script |
| `GET /__opentraffic/macapp/viewer.css` | The viewer styles |
| `GET /__opentraffic/macapp/icon.png` | The app's icon |
| `GET /__opentraffic/macapp/snapshot.png?window=<id>` | The window's full current frame as PNG |
| WebSocket `/__opentraffic/macapp/ws` | Everything live, below |

All mirror paths start with `/__opentraffic/macapp/`; a proxy in front passes that prefix through
untouched. The WebSocket refuses (403) pages from other sites: its `Origin` must be a loopback address,
the request's own `Host`, or an origin the session allows, so a proxy that rewrites `Host` must have
the share's public origin allowed.

## WebSocket rules

- Server to client: JSON **text** messages, plus **binary** messages that carry frame tiles (only
  ever right after a `frame` message). Client to server: JSON text messages only.
- Every JSON message is an object with its type in `t`.
- **Optional fields are always written**, as `null` when absent, so readers see `null`, never
  `undefined`. Readers treat a missing optional field as `null` (or as the default named below).
- **Unknown fields are ignored** and **unknown `t` values are ignored** (not errors) on both sides, so
  later versions only add fields and messages.
- Ids: window ids are unsigned 32-bit integers. All geometry is in **points** (not pixels).
- Several viewers can be connected to one app at once; each gets the full stream.

On connect the server sends `hello`, then a full `tree` for every window, then a full `frame` for every
window, then live updates.

## Server to client

### `hello`

```json
{"t":"hello","boot":"6F1C7D0E-2D7B-4E55-9C59-0B5A3C1D2E3F","scale":2,"appearance":"dark","app":{"name":"Orbit"},
 "windows":[{"id":1,"title":"","w":860,"h":572,"x":0,"y":0,"kind":"main","parent":null}]}
```

- `boot`: a UUID per app launch. If it differs from the `boot` the viewer saw before (after a
  reconnect), the app restarted: clear the layer, every window and every canvas.
- `scale`: the backing scale of the frames. A tile of `w`×`h` points is an image of `w*scale` by
  `h*scale` pixels. Draw canvases at CSS size `w`×`h` with a backing store `scale` times larger.
- `appearance`: `"dark"` or `"light"`, the app's current appearance.
- `app.name`: the app's display name.
- `windows`: as in `windows` below.

### `windows`

```json
{"t":"windows","windows":[
  {"id":1,"title":"","w":860,"h":572,"x":0,"y":0,"kind":"main","parent":null},
  {"id":2,"title":"New Order","w":400,"h":220,"x":230,"y":28,"kind":"sheet","parent":1}]}
```

The full window list, sent whenever a window appears, moves, resizes or closes. A window missing
from the list is gone: remove its surface and layer.

| Field | Meaning |
| --- | --- |
| `id` | Window id (UInt32); the same id in `tree`, `frame`, tiles and client messages |
| `title` | The window's title, `""` when none |
| `w`, `h` | Size in points |
| `x`, `y` | Position in points relative to the main window's top-left (the main window is at 0,0) |
| `kind` | `main`, `sheet`, `alert`, `popover`, `menu` or `window` (a second ordinary window) |
| `parent` | The id of the window a sheet/alert/popover/menu belongs to, else `null` |

v1 servers may send only `main`; the other kinds come with the extra-windows work, without changes to
this shape.

### `tree`

```json
{"t":"tree","window":1,"v":"9f3a01c2","nodes":[
  {"key":"/Window:","role":"AXWindow","label":"","value":null,"x":0,"y":0,"w":860,"h":572,"depth":0,
   "enabled":true,"focused":false,"selected":false,"actions":[]},
  {"key":"/Window:/Group:/Button:Add Order","role":"AXButton","label":"Add Order","value":null,
   "x":226,"y":530,"w":86,"h":24,"depth":2,"enabled":true,"focused":false,"selected":false,"actions":["press"]}]}
```

A **full snapshot** of one window's accessibility tree; there are no deltas in v1. Replace the
window's layer with it, reconciling by `key` (reuse elements whose key survives). `v` identifies the
content: two snapshots with the same `v` are identical. Nodes come in document order (a parent before
its children).

| Field | Meaning |
| --- | --- |
| `key` | Stable id of the element, see [Node keys](#node-keys) |
| `role` | The raw AX role string, passed through: `AXButton`, `AXCheckBox`, `AXTextField`, `AXSecureTextField`, `AXStaticText`, `AXRadioButton`, `AXIncrementor`, `AXRow`, ... |
| `label` | The element's name (AXDescription, else AXTitle, else the value of static text); `""` when none |
| `value` | The value as a string (checkboxes and radio buttons `"0"`/`"1"`, text fields their text, steppers the number), or `null` |
| `x`, `y`, `w`, `h` | Frame in points relative to **this window's** top-left; all four `0` when the element is out of sight (no size, or wholly outside the window or a scroll area around it). An element scrolled out of view (like a list row) keeps its node and key but its contents are left out until it scrolls in |
| `depth` | 0 for the window, 1 for its children, ... |
| `enabled`, `focused`, `selected` | AXEnabled, AXFocused, AXSelected |
| `actions` | The protocol actions the element supports, from: `press`, `increment`, `decrement`, `confirm`, `cancel`, `showMenu`, `scrollToVisible` |

The action names map to AX actions: `press` AXPress, `increment` AXIncrement, `decrement`
AXDecrement, `confirm` AXConfirm, `cancel` AXCancel, `showMenu` AXShowMenu, `scrollToVisible`
AXScrollToVisible. Other AX actions are not part of the protocol.

### `frame` and binary tiles

```json
{"t":"frame","window":1,"seq":12,"full":false,"tiles":3}
```

Announces that exactly `tiles` binary messages follow, each one tile of window `window`. `seq` counts
frames per window. `full: true` means the tiles cover the whole window (the first frame, and after a
resize); otherwise they are only the parts that changed. Paint each tile at its `x`,`y` in the
window's canvas.

Each binary message is a 17-byte header followed by the encoded image. All integers are
**big-endian** (network order, `DataView`'s default):

| Offset | Type | Field |
| --- | --- | --- |
| 0 | UInt32 | `window` |
| 4 | UInt32 | `seq` (equals the preceding `frame`'s `seq`) |
| 8 | UInt16 | `x` (points, from the window's top-left) |
| 10 | UInt16 | `y` |
| 12 | UInt16 | `w` (points; the image is `w*scale` by `h*scale` pixels) |
| 14 | UInt16 | `h` |
| 16 | UInt8 | `format`: 0 JPEG, 1 WebP |
| 17 | bytes | the image, to the end of the message |

```js
socket.binaryType = "arraybuffer";
function readTile(buffer) {
  const v = new DataView(buffer);
  const type = v.getUint8(16) === 1 ? "image/webp" : "image/jpeg";
  return {
    window: v.getUint32(0), seq: v.getUint32(4),
    x: v.getUint16(8), y: v.getUint16(10), w: v.getUint16(12), h: v.getUint16(14),
    image: new Blob([new Uint8Array(buffer, 17)], { type }),
  };
}
// createImageBitmap(tile.image) then ctx.drawImage(bitmap, x*scale, y*scale) on the window's canvas.
```

### `cursor`

```json
{"t":"cursor","shape":"pointer"}
```

The app's cursor: `default`, `pointer`, `text` or `grab`. Map to the same CSS `cursor` names.

### `status`

```json
{"t":"status","state":"restarting","message":"Rebuilt; restarting Orbit"}
```

`state` is `running`, `restarting`, `crashed` or `stopped`; `message` is a human sentence or `null`.
Show a banner for anything but `running`.

### `menu`

```json
{"t":"menu","bar":[
  {"title":"Orbit","enabled":true,"checked":false,"shortcut":null,"separator":false,"items":[
    {"title":"About Orbit","enabled":true,"checked":false,"shortcut":null,"separator":false,"items":[]}]},
  {"title":"Orders","enabled":true,"checked":false,"shortcut":null,"separator":false,"items":[
    {"title":"Mark All Shipped","enabled":true,"checked":false,"shortcut":"⇧⌘S","separator":false,"items":[]},
    {"title":"","enabled":false,"checked":false,"shortcut":null,"separator":true,"items":[]},
    {"title":"Filter","enabled":true,"checked":false,"shortcut":null,"separator":false,"items":[
      {"title":"All","enabled":true,"checked":true,"shortcut":null,"separator":false,"items":[]}]}]}],
 "context":null}
```

The app's menu bar and the menu it has popped up, if any. Sent on connect once the menus have been
read (after the trees, before the frames) and again whenever either changes; servers without menus
never send it.

`bar` lists the app's top-level menus in order. The first is the app's own menu, titled with its name
(on a Mac the bold name in the menu bar). Each menu item:

| Field | Meaning |
| --- | --- |
| `title` | The item's title (`""` for a separator) |
| `enabled` | Whether it can be chosen now |
| `checked` | Whether it shows a checkmark |
| `shortcut` | The key equivalent as macOS shows it, or `null`: modifiers in the order `fn` `⌃` `⌥` `⇧` `⌘`, then the key: a capital letter, a digit or punctuation, `Space`, `F1`…`F19`, or a symbol (`↩` `⌤` `⎋` `⌫` `⌦` `⇥` `←` `→` `↑` `↓` `↖` `↘` `⇞` `⇟`) |
| `items` | A submenu's items (`[]` for a plain item); a submenu is never chosen itself, and has no `shortcut` |
| `separator` | A line between groups of items |

The server leaves out what reaches beyond the shared app or would take its window away from the
viewers: the Apple menu (the host's Mac), Services, AutoFill, Dictation, Emoji & Symbols, Hide,
Hide Others, Show All, Quit, full screen, minimize and window tiling. It can't choose them either.
Menus are read through Accessibility, and some apps update an item's checkmark or enabled state only
when the menu is about to open on screen, so those two may lag behind the app.

`context` is `null`, or the menu the app has popped up (a context menu after a right click, a pop-up
button's menu):

| Field | Meaning |
| --- | --- |
| `window` | The window it belongs to |
| `x`, `y` | Its top-left corner in points relative to that window's top-left; show the menu there |
| `items` | Its items, as above |

While the app has a menu open it waits for an answer: choose an item or close it with `menuAction`
(below). A press anywhere else in the viewer should close it (and, as on a Mac, go no further).
Viewers see the same context menu, whoever right-clicked.

### `control` (reserved: viewer options)

```json
{"t":"control","mode":"everyone","you":true}
```

`mode` is `everyone`, `watchOnly` or `askToControl`; `you` says whether this viewer may control the
app now. Reserved for the viewer-options work; until it is sent, everyone controls.

## Client to server

The server applies a connection's messages in order. It never takes raw accessibility handles from
the client: `key`s are resolved against the window's **latest** snapshot, and a key that no longer
exists is ignored.

| Message | Meaning |
| --- | --- |
| `{"t":"act","window":1,"key":"/Window:/Group:/Button:Add Order","action":"press"}` | Perform an action (one of the node's `actions`) on the node |
| `{"t":"pointer","window":1,"kind":"move","x":10,"y":20,"dx":0,"dy":-30,"modifiers":["shift"]}` | A pointer event at window-relative points |
| `{"t":"text","window":1,"text":"Ada"}` | Type Unicode text at the app's current focus |
| `{"t":"key","window":1,"code":"Enter","modifiers":["cmd"]}` | Press one named key |
| `{"t":"setText","window":1,"key":"/Window:/Group:/TextField:Customer","value":"Ada Lovelace"}` | Replace a field's whole value (the server focuses it, selects all, types) |
| `{"t":"viewport","w":1200,"h":700,"appearance":"dark"}` | Reserved (viewer options): the viewer's usable size in CSS pixels and its `prefers-color-scheme` (`dark`, `light` or `null`) |
| `{"t":"menuAction","path":["Orders","Mark All Shipped"],"context":false}` | Choose a menu item by its titles, from the menu bar down; with `"context":true` from the open context menu down (`["Duplicate"]`), and an empty `path` closes the context menu without choosing |
| `{"t":"requestControl"}` | Reserved (viewer options): ask the host for control in `askToControl` mode |

- `pointer.kind`: `move`, `down`, `up`, `rightdown`, `rightup`, `wheel`. `dx`/`dy` are wheel
  deltas in points (positive `dy` scrolls content down, as in DOM `WheelEvent.deltaY`) and `0` for the
  other kinds; the client may omit `dx`, `dy` and `modifiers`.
- `key.code`: `Enter`, `Escape`, `Tab`, `Backspace`, `Delete`, `ArrowUp`, `ArrowDown`, `ArrowLeft`,
  `ArrowRight`, `Space` (DOM `KeyboardEvent.key` names, with `Space` for `" "`).
- `modifiers` (pointer and key): any of `cmd`, `shift`, `alt`, `ctrl`; may be omitted (`[]`).
- `menuAction.context` may be omitted (`false`). A path that doesn't lead to an item the `menu`
  message offered, or to a disabled item, is ignored. Titles are matched exactly; with two items of
  the same title in one menu the first is chosen.
- A right click is `pointer` `rightdown` then `rightup`; if the app pops up a context menu, a `menu`
  message with `context` follows (usually within half a second). `act` `showMenu` opens an element's
  context menu the same way, for viewers without a right button.
- **Menu shortcuts.** Cmd key combinations sent as `key` events don't reach an app that isn't the
  frontmost app on the host's Mac, so a viewer sends a shortcut that belongs to a menu item as that
  item's `menuAction`. The viewer page matches the key event against the `shortcut` of every item:
  letters and digits by `KeyboardEvent.code` (`KeyS`, `Digit1`) with Shift exactly as listed,
  named keys by `KeyboardEvent.key` (`↩` is `Enter`), punctuation by `KeyboardEvent.key` (Shift may be
  what types it). It leaves copy, cut and paste to the browser (the host's clipboard is no use to a
  viewer), and select all and undo too while one of its fields has focus.

## Node keys

A key names an element by its path from the window, so it survives re-snapshots:

- One segment per level: `/<role without the AX prefix>:<label>`. The window itself is always
  `/Window:` (its title is left out, so keys survive a title change).
- The label is cut to 40 characters; runs of whitespace (newlines, tabs) become one space and `/`
  becomes `∕` (U+2215), so a label never splits the path. An element without a label ends in `:`.
- When siblings would have the same segment, the second gets `#2`, the third `#3`, and so on; the
  first keeps the bare segment.

Examples: `/Window:/Group:/Button:Add Order`, `/Window:/Group:/List:/Row:Grace Hopper#2`.

The viewer treats keys as opaque strings. The DOM id of a node's element is `ax-` + the djb2 hash of
the key over its UTF-16 code units, as an unsigned 32-bit number in base 36:

```js
function domId(key) {
  let h = 5381;
  for (let i = 0; i < key.length; i++) h = ((h << 5) + h + key.charCodeAt(i)) >>> 0;
  return "ax-" + h.toString(36);
}
domId("/Window:/Group:/Button:Add Order"); // "ax-3tt01y"
```

`MirrorProtocol.NodeKey.domID(for:)` computes the same id in Swift (tests pin both to the same
values), so a comment pinned to `#ax-3tt01y` finds the same element on the host side.
