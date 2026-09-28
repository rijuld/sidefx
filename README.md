<div align="center">

# 🧾 sidefx

**A receipt for everything your Rails code actually did.**

Wrap any block, test or request and get a receipt of its side effects: rows written
per table, callbacks fired, jobs enqueued, mail sent, HTTP called, cache changed,
broadcasts made, and what a rollback quietly undid. Assert on it, and surprise side
effects fail CI with a receipt that shows exactly what happened.

![license: MIT](https://img.shields.io/badge/license-MIT-blue)
![rails: 7.1+](https://img.shields.io/badge/rails-7.1%2B-CC0000)
![runtime deps: activerecord + activesupport](https://img.shields.io/badge/runtime%20deps-2-brightgreen)

</div>

---

## Why

`user.save` in a real Rails app can write to four tables, enqueue two jobs, send an
email, bust a cache and call Stripe, through callbacks, concerns and gems you didn't
write. You can't see any of that at the call site. Legacy code hides it, and code
written by AI agents hides it more: it *looks* like one line.

sidefx makes the invisible part visible:

- **In the console:** `Sidefx.print { order.cancel! }` shows what cancelling actually
  does before you do it in production.
- **In tests:** `assert_side_effects(writes: { orders: 1 }, http: 0) { ... }` pins down a
  flow's effects, so a new callback that emails every customer fails CI.
- **In development:** it warns in the log when a `GET` request writes to the database
  or enqueues jobs. No configuration needed.

## The receipt

This is real output from [`examples/checkout.rb`](examples/checkout.rb), a checkout
service with the usual Rails furniture (run it: `bundle exec ruby examples/checkout.rb`):

```text
============================================================
                        S I D E F X
                    side-effect receipt
                       Checkout#call
               2026-09-28 19:17:50 · 33.7 ms
------------------------------------------------------------
DATABASE WRITES
  UPDATE products ×4 ................................ 4 rows
      ↳ examples/checkout.rb:113
  INSERT orders ...................................... 1 row
      ↳ examples/checkout.rb:115
  UPDATE customers ................................... 1 row
      ↳ examples/checkout.rb:115
  INSERT line_items ×4 .............................. 4 rows
      ↳ examples/checkout.rb:115
------------------------------------------------------------
JOBS ENQUEUED
  FulfillmentJob ................................... default
      at 23:27:50Z
      ↳ examples/checkout.rb:68
------------------------------------------------------------
EMAILS
  OrderMailer#confirmation ................... deliver_later
      ↳ examples/checkout.rb:123
------------------------------------------------------------
HTTP REQUESTS
  POST 127.0.0.1:50634/v1/charges ...................... 201
      ↳ examples/checkout.rb:97
------------------------------------------------------------
BROADCASTS
  orders ................................................. 1
      ↳ examples/checkout.rb:122
------------------------------------------------------------
CACHE CHANGES
  delete storefront/stock ................................ 1
      ↳ examples/checkout.rb:121
------------------------------------------------------------
ROLLED BACK · these did not happen
  INSERT audit_logs .................................. 1 row
      ↳ examples/checkout.rb:133
------------------------------------------------------------
CALLBACKS RUN
  Order save ............................................ ×1
      before_save :compute_total
        ↳ examples/checkout.rb:63
  Order commit .......................................... ×1
      after_commit :schedule_fulfillment (conditional)
        ↳ examples/checkout.rb:67
  (+5 chains with only framework callbacks)
------------------------------------------------------------
READS .................................. 4 queries · 1 table
  ! N+1? SELECT products ×4  examples/checkout.rb:111
============================================================
TOTAL SIDE EFFECTS ...................................... 15
ROLLED BACK .............................................. 1
============================================================
                   thank you, come again
```

Every line points at *your* code, not at Active Record's internals. Three things
you'd likely miss reading this code:
- The audit log write lives in a savepoint that gets rolled back.
- The customer's counter cache is updated.
- There's an N+1 on products.

## Install

```ruby
# Gemfile
gem "sidefx", github: "rijuld/sidefx"
```

Runtime dependencies are only `activerecord` and `activesupport`. Mailer, job, cable
and HTTP tracking switch on when those libraries are loaded.

## Usage

### Console and scripts

```ruby
Sidefx.print { User.find(42).destroy }            # prints the receipt, returns the block's value

receipt = Sidefx.receipt("import") { CsvImport.new(file).run }
receipt.writes      # => { "products" => 120, "prices" => 120 }
receipt.jobs        # => ["ReindexJob"]
receipt.mails       # => ["AdminMailer#import_finished"]
receipt.http        # => ["POST api.algolia.net/1/indexes/products/batch"]
receipt.rolled_back # => [#<struct Sidefx::Effect label="INSERT audit_logs" ...>]
receipt.escaped_rollback # => effects that happened inside a rolled-back transaction anyway
receipt.n_plus_ones # => [["SELECT ... FROM prices WHERE product_id = ?", "prices", 120]]
receipt.pure?       # => false
receipt.summary     # => "240 rows written (products, prices), 1 job, 1 mail, 1 HTTP call · 245 reads · 812.4 ms"
receipt.to_h        # plain hash, handy for JSON
```

### Minitest

```ruby
# test/test_helper.rb
require "sidefx/minitest"
```

```ruby
test "signing up only creates the user" do
  assert_side_effects(writes: { users: 1 }, jobs: 0) do
    post signup_path, params: { user: { email: "grace@example.com" } }
  end
end

test "the dashboard is read-only" do
  assert_no_side_effects { get dashboard_path }
end
```

When it fails, the message is the receipt. Real output:

```text
DemoTest#test_signup_only_creates_a_user [test/zz_demo_fail.rb:5]:
Side effects didn't match:
  writes: audit_logs expected 0, got 1
  jobs: expected 0, got 1 ["FulfillmentJob"]

============================================================
                        S I D E F X
                    side-effect receipt
                2026-09-28 19:17:50 · 5.6 ms
------------------------------------------------------------
DATABASE WRITES
  INSERT users ....................................... 1 row
      ↳ test/zz_demo_fail.rb:6
  INSERT audit_logs .................................. 1 row
      ↳ test/zz_demo_fail.rb:7
------------------------------------------------------------
JOBS ENQUEUED
  FulfillmentJob ................................... default
      ↳ test/zz_demo_fail.rb:8
============================================================
TOTAL SIDE EFFECTS ....................................... 3
============================================================
                   thank you, come again
```

### RSpec

```ruby
# spec/spec_helper.rb
require "sidefx/rspec"

expect { checkout.call }.to have_side_effects(writes: { orders: 1 }, mails: ["OrderMailer#confirmation"])
expect { get "/dashboard" }.not_to have_side_effects
```

### What you can assert

Each key you pass is checked exactly; keys you leave out aren't checked.

| Key | Value | Notes |
| --- | --- | --- |
| `writes:` | `{ orders: 1 }` or an Integer | rows per table (unlisted tables must be 0), or total rows |
| `jobs:` | `["FulfillmentJob"]` or an Integer | job class names |
| `mails:` | `["OrderMailer#confirmation"]` or an Integer | same name for `deliver_now` and `deliver_later` |
| `http:` | `["POST api.stripe.com/v1/charges"]` or an Integer | method, host, path (no query string) |
| `broadcasts:` | `["orders"]` or an Integer | Action Cable / Turbo stream names |
| `cache:` | `["delete storefront/stock"]` or an Integer | writes, deletes, increments |

Array entries can be Strings or Regexps. Reads never count as side effects.

### Development: unsafe GETs

With no configuration, sidefx adds a middleware in development that stays silent
until a `GET`/`HEAD` request writes, enqueues, mails or broadcasts. Then it logs the
receipt. This is real output from a fresh Rails 8.1 app whose `show` action does
`post.increment!(:views)`:

```text
[sidefx] GET /posts/hello is a safe method but changed things:
============================================================
                        S I D E F X
                    side-effect receipt
                      GET /posts/hello
               2026-09-28 19:16:23 · 43.3 ms
------------------------------------------------------------
DATABASE WRITES
  INSERT posts ....................................... 1 row
  UPDATE posts ....................................... 1 row
      ↳ app/controllers/posts_controller.rb:4
...
```

```ruby
# config/environments/development.rb
config.sidefx.requests = :log   # one summary line for every request
config.sidefx.requests = false  # off
```

## How it works

- **Rails' own instrumentation.** It subscribes to `sql.active_record`,
  `transaction.active_record`, `enqueue*.active_job`, `deliver.action_mailer`,
  `broadcast.action_cable` and `cache_*.active_support`. There's no monkey-patching of
  your models.
- **Two small prepends:** `Net::HTTP#request` for outgoing HTTP, and
  `ActiveRecord::Base#run_callbacks` to note which callback chains ran. Declared
  callbacks are read from the chain with their source locations; framework-internal
  ones are counted, not listed.
- **Per thread.** Events from other threads (Puma workers, parallel tests) never land in
  your receipt. Receipts nest: an inner receipt's effects also appear in the outer one.
- **Rollbacks are tracked properly,** including savepoints (`requires_new: true`) and
  the savepoints Rails creates inside transactional tests. Database writes inside a
  transaction that rolls back move to *ROLLED BACK*, and assertions only count rows
  that stuck. Everything else (an email, an HTTP charge, a job on a Redis-backed queue)
  **still happened**, so it stays on the receipt with a warning: *"ran inside a
  transaction that rolled back"*. `receipt.escaped_rollback` lists them.
- **Honest naming.** `deliver_later` is shown as mail, not as `MailDeliveryJob`. Inserts
  into `solid_queue_*` / `good_job` tables are the job enqueue itself, so they aren't
  double-counted as writes. `SCHEMA`, cached and `BEGIN/COMMIT` queries are ignored.

### Limitations

- HTTP is seen through `Net::HTTP`, which covers Faraday's default adapter, HTTParty,
  RestClient, ActiveResource and most SDKs. Clients built on libcurl (Typhoeus, curb)
  or raw sockets aren't seen.
- A callback marked *conditional* has an `if:`/`unless:`/`on:` condition. It's listed
  because its chain ran, which doesn't prove the callback itself did.
- Effects made while a streaming response body is written happen after the middleware
  returns, so they're not in the request receipt.
- Writes through raw connections that bypass Active Record instrumentation aren't seen.
- Tested on Ruby 4.0 and Rails 8.1. The gemspec allows Rails 7.1+, and CI will say
  whether that holds.

## Prior art

- [isolator](https://github.com/palkan/isolator) and
  [TransactionGuard](https://dev.to/yashika_vijayvargiya/your-rails-transaction-rolled-back-what-happened-to-the-api-call-email-or-job-33m4)
  catch *non-atomic* side effects inside transactions. sidefx answers a broader
  question: everything a block did, inside a transaction or not.
- [bullet](https://github.com/flyerhzm/bullet) and
  [prosopite](https://github.com/charkost/prosopite) specialize in N+1 detection. sidefx
  only flags repeated query shapes as a hint.
- Active Record's `assert_queries_count` counts queries. sidefx names the writes.

## Contributing

Issues and PRs are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). The test suite runs
against an in-memory SQLite app and a local TCP server, with no network or database
setup.

### Roadmap

Good first issues are marked 🌱.

- 🌱 Active Storage uploads and deletes as effects
- 🌱 `receipt.to_json` and a `SIDEFX_OUT=receipts.jsonl` env var for CI artifacts
- 🌱 Redis commands via `redis-client` instrumentation
- Mark jobs deferred by `enqueue_after_transaction_commit` that were dropped by a rollback
- `sidefx diff`: compare two receipts to see what a refactor changed
- A `Sidefx.snapshot` test helper that stores receipts as golden files

## License

MIT. See [LICENSE](LICENSE).
