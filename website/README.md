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

`remotion/` holds two [Remotion](https://www.remotion.dev) compositions: `Promo`, the short video with
music at the top of the page and (as a GIF) in the README, and `Demo`, the longer walkthrough the page
links to:

```sh
npm run studio     # preview and edit
npm run promo      # out/opentraffic-promo.mp4, with its music and sound mastered
npm run video      # public/media/demo.mp4 (the walkthrough) and its poster
npm run video:gif  # ../docs/images/demo.gif for the README, from out/opentraffic-promo.mp4
```

`public/media/promo.mp4` is a smaller web encode of `out/opentraffic-promo.mp4` (x264 at CRF 23,
160 kb/s AAC, `-movflags +faststart`).

Remotion is free for individuals and companies of up to three people; larger companies need a
[company license](https://www.remotion.pro).
