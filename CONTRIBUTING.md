# Contributing to sidefx

Thanks for helping make side effects visible. 🧾

## Setup

```sh
bundle install
bundle exec rake test               # in-memory SQLite, no services needed
bundle exec ruby examples/checkout.rb
```

## Codebase tour

| File | What it does |
| --- | --- |
| `lib/sidefx.rb` | `Sidefx.receipt` / `Sidefx.print`, and deciding which stack frames are "your code". |
| `lib/sidefx/recorder.rb` | Notification subscribers, the per-thread receipt stack, transaction frames for rollbacks. |
| `lib/sidefx/receipt.rb` | The data: effects, reads, callbacks, and queries like `writes` / `jobs`. |
| `lib/sidefx/printer.rb` | The receipt you see. |
| `lib/sidefx/sql.rb` | Tiny SQL classifier (`INSERT orders`) and query-shape normalizer. |
| `lib/sidefx/http.rb`, `callbacks.rb` | The only two prepends. |
| `lib/sidefx/expectation.rb` | Assertion logic shared by Minitest and RSpec. |
| `lib/sidefx/middleware.rb`, `railtie.rb` | The development request warnings. |

## Adding a new kind of side effect

1. Find the `ActiveSupport::Notifications` event in the Rails source (don't guess the
   payload keys) and add it to `Recorder::EVENTS`.
2. Handle it in `Recorder.dispatch` and call `effect(kind, label, ...)`.
3. Add a section to `Printer::SECTIONS` and an accessor to `Receipt`.
4. Write a test in `test/receipt_test.rb` that exercises the real library, not a fake event.

## Ground rules

- **Never break the host app.** Recorder errors are swallowed (`SIDEFX_DEBUG=1` shows them).
- **Nothing is recorded unless a receipt is open** on the current thread. Keep the
  inactive path to a single check.
- Runtime dependencies stay at `activerecord` and `activesupport`.
- Labels are what a person would say: `OrderMailer#confirmation`, not `ActionMailer::MailDeliveryJob`.
