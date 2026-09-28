# Changelog

## 0.1.0 (unreleased)

- `Sidefx.receipt` / `Sidefx.print` record database writes, callbacks, jobs, mail,
  HTTP (Net::HTTP), cache changes and Action Cable broadcasts for a block.
- Rollbacks and savepoints are tracked; rolled-back effects are reported separately.
- Repeated read shapes are flagged as possible N+1 queries.
- Minitest assertions (`assert_side_effects`, `assert_no_side_effects`) and an RSpec
  matcher (`have_side_effects`).
- Development middleware that warns when GET/HEAD requests change things.
