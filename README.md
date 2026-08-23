# capybara-simulated-vs-world

Real-world Rails apps run against
[capybara-simulated](https://github.com/ursm/capybara-simulated). Each
target app is a git submodule pinned to a specific SHA. The runner
injects the simulated driver via `RUBYOPT` (no patches to upstream
spec files) and skips an explicit list of tests we already know we
can't satisfy without a real browser, each with a written reason.

## Coverage

Browser-driven system specs that exercise capybara-simulated end-to-end
on each target app. *Unsupported* tests are listed in `lists/<app>.yml`
with a per-test reason — most boil down to a real layout engine being
needed (drag-and-drop coordinates, scroll-tied sticky headers, SVG
paths drawn from computed bounding boxes) or a Selenium-/cuprite-
specific API leak (`page.driver.browser.action`,
`Capybara.current_session.server.port`). *Failed* should stay at 0; if
it climbs, something regressed and the right move is a fix or a new
list entry, not a hand-wave.

## Layout

```
apps/<name>/                # submodule, SHA-pinned to a known-good upstream commit
Gemfile.<name>              # eval upstream's Gemfile + layer capybara-simulated/quickjs
support/csim_minitest.rb    # RUBYOPT preload for Minitest hosts (Redmine)
support/csim_rspec.rb       # RUBYOPT preload for RSpec hosts (Forem)
lists/<name>.yml            # `{test:, reason:[, engine:][, skip:][, fresh_http_cache:]}`
                            # per-test list — `test:` is an exact description /
                            # location string or a Regexp
bin/run-<name>              # cd into the app, set BUNDLE_GEMFILE/RUBYOPT,
                            # exec the host's test runner
```

The preload files do two things:

1. Override `ActionDispatch::SystemTestCase.driven_by` so any
   `driven_by :selenium` / `:better_cuprite` / etc. routes to
   `:simulated` (with `:rack_test` left alone).
2. Read `lists/<name>.yml` and turn matched failures into skips with
   the listed reason. If a listed test passes, the run fails with an
   "expected failure but passed — drop it from the list" message so
   stale list entries don't hide regressions.

## Adding a new app

1. `git submodule add <repo-url> apps/<name>` and check out the SHA you
   want to pin against.
2. Create `Gemfile.<name>` that `eval_gemfile`s the upstream Gemfile
   and layers `capybara-simulated` (path) + `quickjs` (git) on top.
3. Create `bin/run-<name>` modelled on `bin/run-redmine` /
   `bin/run-forem` — it exports `BUNDLE_GEMFILE`, `RUBYOPT`, and any
   app-specific env (e.g. `APP_PROTOCOL`, `COMMUNITY_NAME`).
4. Start with an empty `lists/<name>.yml` (`[]`), run the suite, and
   move every real failure into the list with a written reason.
5. Re-run; the run is green when every non-listed test passes and
   every listed test still fails.

## Running

```sh
bin/run-redmine                            # full minitest suite
bin/run-redmine test/system/issues_test.rb # one file
bin/run-redmine test/system/issues_test.rb:42

bin/run-forem                              # `:js`-tagged system specs
bin/run-forem spec/system/articles         # one subdir
bin/run-forem spec/system/articles/user_visits_an_article_spec.rb:42
```

Both runners exit non-zero if any non-listed test fails OR any listed
test passes unexpectedly. Set `CSIM_EXPECTED_FAILURES=/dev/null` to run
without the skip list (useful when you're hunting the actual failure
shape of something on the list).

## Why not patch each app's `rails_helper.rb` / `application_system_test_case.rb`?

Upstream changes would conflict every release, and we want the same
source tree to still run cuprite / selenium when needed. The RUBYOPT
preload pattern means switching driver is one env-var flip away,
nothing in the submodule changes.

## Working against a local capybara-simulated checkout

The Gemfiles default to the `main` branch on GitHub. To point at a
sibling working copy instead, set `CAPYBARA_SIMULATED_PATH` to the
path before running:

```sh
CAPYBARA_SIMULATED_PATH=../capybara-simulated bin/run-discourse
```

The env var goes through `path:` so live edits to the gem reflect
immediately — no need to push a commit per iteration.

## Per-app Ruby

Each `bin/run-<name>` declares its own `RUBY_VERSION` and shells out
through `mise exec ruby@<ver>` when mise is on PATH. In CI,
`actions/setup-ruby` puts the matching Ruby on PATH and mise isn't
installed, so the script falls through to a plain `bundle exec`. No
`.tool-versions` at the repo root.
