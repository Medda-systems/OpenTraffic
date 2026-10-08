# opentraffic.dev

The landing page: Vite, React, Tailwind, and shadcn/ui, styled after medda.se. It's served as a static
Cloudflare Worker (`wrangler.jsonc`) on opentraffic.dev and www.opentraffic.dev.

```sh
npm install
npm run dev        # http://localhost:5173
npm run deploy     # build and publish to Cloudflare
```

`public/_redirects` gives the short links `opentraffic.dev/install` (the one-line installer) and
`opentraffic.dev/download` (the newest disk image). Add `?static` to the URL to turn off the entrance
animations, for screenshots.

## The demo video

`remotion/` is a [Remotion](https://www.remotion.dev) composition of the demo on the page and in the
READMEs (the same scenes rendered three ways):

```sh
npm run studio     # preview and edit
npm run video      # public/media/demo.mp4 and its poster
npm run video:gif  # ../docs/images/demo.gif for the README
```

Remotion is free for individuals and companies of up to three people; larger companies need a
[company license](https://www.remotion.pro).
