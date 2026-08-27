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

# 2. one-off tooling
npm i pg playwright

# 3. serve the mock + the site
PGUSER="$(whoami)" node tests/frontend/mock-supabase.js &

# 4. drive the browser
node tests/frontend/e2e.test.js
```

`e2e.test.js` exits non-zero on the first failed check.

## Notes

- It stubs `window.open` rather than following the `wa.me` link, and
  asserts on the URL the page built.
- `cdn.simpleicons.org` is optional: when it cannot be reached, every
  product falls back to its designed monogram. The test tolerates that.
