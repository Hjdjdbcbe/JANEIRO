# Frontend integration test

Drives the real `frontend/index.html` in Chromium against a mock Supabase
that is backed by the local test database — so the whole flow (catalogue
→ cart → order → receipt → confirm → WhatsApp → tracking) is exercised
without a deployed project.

`mock-supabase.js` is **not** a PostgREST implementation. It answers only
the queries `js/janeiro-api.js` actually issues, and it runs them through
the `anon` role so RLS applies exactly as it would in production. Its
value is proving the frontend↔backend contract: query shapes, embedded
relations, error codes and the order of the three write calls.

## Run

```bash
# 1. the local database must exist (creates/reseeds it)
bash tests/local/run-tests.sh

# 2. store config the browser tests need: a WhatsApp number, payment
#    account details, two category icon paths and two live deals
psql -d janeiro_test -f tests/frontend/fixtures.sql

# 3. one-off tooling
npm i pg playwright

# 4. serve the mock + the site
PGUSER="$(whoami)" node tests/frontend/mock-supabase.js &

# 5. drive the browser
node tests/frontend/e2e.test.js   # catalogue, cart, order, tracking
node tests/frontend/ui.test.js    # icons, deals, motion, narrow viewports
```

Both exit non-zero on the first failed check.

`run-tests.sh` drops and recreates the database, so re-apply
`fixtures.sql` after every backend run or the deals section will
correctly render as hidden and the deal assertions will fail.

## What ui.test.js covers

- **Category icons** — the tile in all three placements, tinted from
  `accent_color`; an uploaded `icon_path` rendering as a lazy 128x128
  image through the public bucket; the designed glyph showing when there
  is no asset, when the asset 404s, and *underneath* a working image so
  a lazy load never leaves a blank tile.
- **Deals** — the section rendering live deals with the struck price and
  the discount percentage, the countdown actually counting down, the
  deal price following through to the detail page and the cart total,
  and the section hiding entirely when the server returns no deals.
- **Motion** — the stagger step capped at 60ms and the total at 300ms,
  no interaction transition over 400ms, nothing transitioning a layout
  property, the orbit ring at 60s, one short cart pulse, and
  `prefers-reduced-motion` leaving nothing animating or stuck invisible.
- **Layout** — no horizontal scroll at 375, 390 and 430px.

## Notes

- It stubs `window.open` rather than following the `wa.me` link, and
  asserts on the URL the page built.
- `cdn.simpleicons.org` is optional: when it cannot be reached, every
  product falls back to its designed monogram. The test tolerates that.
