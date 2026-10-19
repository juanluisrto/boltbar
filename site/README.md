# Boltbar website

A static page served at https://juanluis.me/boltbar: the trailer, a simulator of
the bar running in the browser, features, privacy and install instructions.

**Hosting.** The files in `site/boltbar/` live in `gs://juanluisrto-public/boltbar/`.
The juanluis.me Next.js site (`juanluisrto/ai-engineer`) rewrites `/boltbar` and
`/boltbar/*` to `storage.googleapis.com/juanluisrto-public/boltbar/...`, proxying
instead of redirecting so visitors stay on juanluis.me. Every link in the page
is absolute (`/boltbar/...`), so the same files work on both hosts.

**Publishing a change** (from the repo root, with the bucket-upload skill's
uploader; `--overwrite` once the objects exist):

    python3 ~/.claude/skills/bucket-upload/scripts/upload.py \
      --workspace personal --visibility public --overwrite site/boltbar

Objects are cached for an hour.

**Previewing.** Serve `site/` at the root so the absolute paths resolve:

    python3 -m http.server 4173 --directory site

then open http://localhost:4173/boltbar/ (and http://localhost:4173/trailer/).

## The bar and its simulator

`bar.js` and `bar.css` recreate the panel from `Views.swift`: palettes, the
code highlighter, message and queue layout, the model chip with its effort
gauge. `playground.js` drives it with the app's keys and rules (Return queues
during a reply, ↑/↓ and ←/→, Esc and ⌥ Space with the summon rule of 0.5.0);
`replies.js` holds the canned answers. Keep them in step with the app when its
interface changes.

## The trailer

`site/trailer/` is the trailer's source and is not uploaded. `trailer.js` paints
every frame as a function of time, reusing `bar.js`. Open
http://localhost:4173/trailer/ to preview it (`?t=12.5` freezes a frame), and
render it with headless Chrome and ffmpeg:

    node site/trailer/render.mjs                    # site/boltbar/assets/trailer.mp4
    node site/trailer/render.mjs --stills 6.2,33 --dir /tmp/stills

`render.mjs` serves `site/` itself and uses the installed Google Chrome. The
poster and the social image come from stills:

    ffmpeg -i t6.20.png -q:v 3 site/boltbar/assets/poster.jpg
    ffmpeg -i t33.00.png -vf "crop=1920:1008:0:36,scale=1200:630" site/boltbar/assets/og.png
