# Design reference for the storefront redesign

- `janeiro-mockup.html`: the target look (static mockup, demo products, no ordering).
- `screens/`: the mockup rendered on a phone (dark, 4 parts top to bottom), phone light, desktop dark.
- `prompt.txt`: the brief for the redesign (Arabic).
- `test-support/pg-shim.js`: a psql-backed stand-in for the `pg` npm module, for running
  `tests/frontend/*.test.js` where npm cannot install `pg`. Copy it to `node_modules/pg/index.js`
  in a folder on NODE_PATH. Test-only.

This branch only carries reference material; it is not meant to be merged.
