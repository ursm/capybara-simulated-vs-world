# capybara-simulated-vs-world

Real-world Rails apps run against
[capybara-simulated](https://github.com/ursm/capybara-simulated). Each
target app is a git submodule pinned to a specific SHA. The runner
injects the simulated driver via `RUBYOPT` (no patches to upstream
spec files) and skips an explicit list of layout-dependent / library-
specific tests we already know we can't satisfy without a real
browser.

## Layout

```
apps/<name>/                     # submodule, SHA-pinned
support/csim_setup.rb            # RUBYOPT preload — registers
                                 # `:simulated` and overrides the app's
                                 # `driven_by(...)` to use it
support/expected_failures.rb     # marks listed examples pending; fails
                                 # the run if a pending test starts
                                 # passing (XFAIL detection)
lists/<name>.yml                 # description-matching skip list
bin/run-<name>                   # `cd apps/<name> && rspec ...`
```

## Adding a new app

1. `git submodule add <repo-url> apps/<name>`
2. `git -C apps/<name> checkout <sha>`
3. Copy `lists/redmine.yml` to `lists/<name>.yml` and trim to that
   app's failures.
4. Copy `bin/run-redmine` to `bin/run-<name>`.

## Running

```sh
bin/run-redmine               # all specs
bin/run-redmine path/to:42    # one example
```

The runner exits non-zero if any non-listed test fails OR any listed
test passed unexpectedly.

## Why not patch each app's `rails_helper.rb`?

Two reasons. Upstream `rails_helper.rb` updates would conflict every
release, and we want to be able to drop the simulated driver in via
env var without permanent app changes — so the same source tree can
still run cuprite / selenium when needed.
