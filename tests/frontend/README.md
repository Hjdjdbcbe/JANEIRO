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
#    and the Telegram bot's side for the dashboard: an owner, a seller,
#    a product with codes and prices, two sales with warranties
psql -d janeiro_test -f tests/frontend/bot-fixtures.sql

# 3. one-off tooling
npm i pg playwright

# 4. serve the mock + the site
PGUSER="$(whoami)" node tests/frontend/mock-supabase.js &

# 5. drive the browser
node tests/frontend/e2e.test.js   # catalogue, cart, order, tracking
node tests/frontend/ui.test.js    # icons, deals, motion, narrow viewports
node tests/frontend/theme.test.js # light/dark theme + measured contrast
node tests/frontend/admin.test.js   # dashboard: login, overview, order queue
node tests/frontend/console.test.js # dashboard: bot stock, sales, warranties, sellers, settings
```

Each exits non-zero on the first failed check.

`run-tests.sh` drops and recreates the database, so re-apply
`fixtures.sql` (then `bot-fixtures.sql`) after every backend run or the deals section will
correctly render as hidden and the deal assertions will fail.

## What ui.test.js covers

Measured against the design reference (`design-reference/`):

- **Category tabs**: text only, one per row of `categories` plus "الكل";
  on the home page they filter the grid in place, with the search box.
- **Product cards**: the 3:4 artwork from `poster_path`, or the drawn
  stand-in in the same shape from `accent_color`; name, description,
  يبدا من + the lowest price, the + button only on single-plan products,
  and اشري دركا.
- **عرض الشهر**: the first live deal (struck list price, discount chip,
  the deal plan preselected and charged in the cart), or a hot product
  when no deal is live.
- **Hero**: badge, two-line heading, three ticks, three fanned cards with
  real artwork first, and the price pill that opens the product.
- **Header, FAQ, WhatsApp band**: nav, ع / FR / EN pills, cart, the FAQ
  opening one card at a time, the number from `store_settings`.
- **Motion**: stagger caps, no transition over 400ms or on layout
  properties, and `prefers-reduced-motion` stopping everything,
  the platforms strip included.
- **Phone layout** (375, 390, 430px): no horizontal scroll, the short
  hero, the strip under the cards, a one-line shop heading, products by
  the second screen, عرض الشهر after the grid.
- **Languages**: FR/EN for every static string, persistence, catalogue
  machine translation.

## What theme.test.js covers

- **Resolution**: dark for every first-time visitor whatever the OS says,
  the sun/moon choice saved and outranking it across a reload, and the
  `data-theme` attribute set by the blocking script in `<head>`.
- **Typography**: Alexandria and IBM Plex Sans Arabic actually render
  (measured by advance width against a forced fallback, since
  `document.fonts.check()` passes even with no `@font-face` at all), are
  self-hosted, take the heading/body roles, are never asked for a weight
  they do not ship, and no Arabic run carries negative letter-spacing.
- **Contrast**: a WCAG 2.1 sweep over *every* visible text node on six
  pages in both themes, compositing translucent fills and scoring the
  worst stop of any gradient, plus pixel-sampled checks of the hero copy
  and the header. Text over product artwork has no
  computable background; those nodes are counted and reported, never
  silently dropped.

It found four real defects on first run, all pre-existing:
white on the brand gradient's blue end (2.86:1), the same on `.badge.new`,
the poster fallback printing its wordmark and warranty chip in the raw
product accent on a wash of that accent (1.1:1), and the brand monogram
using an ink chosen for white on grounds that follow the theme.

## Notes

- It stubs `window.open` rather than following the `wa.me` link, and
  asserts on the URL the page built.
- `cdn.simpleicons.org` is optional: when it cannot be reached, every
  product falls back to its designed monogram. The test tolerates that.
