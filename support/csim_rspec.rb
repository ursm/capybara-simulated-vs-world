# Preloaded via `RUBYOPT='-r<this-file>'` for RSpec-based suites
# (Forem). Mirror of `csim_minitest.rb` with two responsibilities:
#
# 1. Override `ActionDispatch::SystemTestCase.driven_by` so any
#    `driven_by :anything` from the host's RSpec hooks routes to
#    `:simulated` when `CSIM_DRIVER=simulated` is set.
# 2. Skip examples whose `<class>#<method>`-shaped description matches
#    an entry in the expected-failures list at `CSIM_EXPECTED_FAILURES`.

# Bundler activates the gem set BEFORE exec'ing ruby, so $LOAD_PATH is
# already wired up by the time RUBYOPT runs us — but the released
# capybara-simulated 0.0.7 vs the local path version both ship a
# version.rb with the same constant, and requiring without a fresh
# Bundler.require chain double-loads the path-version on top of the
# released-gem one. Forcing `bundler/setup` first locks in the
# Gemfile-resolved version (the local path) before the require.
require 'bundler/setup'

# Cap any single V8 call at 2 minutes (overridable). A nonterminating or
# pathologically slow JS execution inside one call is otherwise UNINTERRUPTIBLE
# (the driver runs V8 on the calling thread with no unblock function, so
# Timeout/SIGTERM never land) — this converts it into a per-example
# `RustyRacer::ScriptTerminatedError` whose #js_backtrace names the hot frame.
# Discourse's ~35% full-suite freeze was exactly this (prosemirror cascade
# blow-up); legitimate calls are ms-scale, so 120s is pure headroom.
ENV['CSIM_V8_CALL_TIMEOUT_MS'] ||= '120000'

# Yama ptrace_scope=1 blocks same-uid rbspy/gdb attach; opt this process
# in so a hung example can be snapshotted from outside
# (`rbspy snapshot --pid <pid>`). PR_SET_PTRACER=0x59616d61 ("Yama"),
# PR_SET_PTRACER_ANY=-1. Harmless where Yama is absent.
begin
  require 'fiddle'
  Fiddle::Function.new(
    Fiddle.dlopen(nil)['prctl'],
    [Fiddle::TYPE_INT, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG],
    Fiddle::TYPE_INT
  ).call(0x59616d61, -1, 0, 0, 0)
rescue StandardError, LoadError
end

# Discourse's `000-mini_racer.rb` initializer sets
# `MiniRacer::Platform.set_flags!(:single_threaded)` for ITS OWN V8
# (PrettyText / theme migrations) whenever
# `GlobalSetting.mini_racer_single_threaded` is truthy — and in test mode
# the BlankProvider forces the production default of true. That costs the
# suite real wall: `lib/asset_processor.rb` calls
# `v8.low_memory_notification` after every JS call when the flag is set
# (a full GC-pressure notification — rbspy: ~5.6% of the about_page
# sample), plus the single-threaded eval path itself. Filter the flag at
# the MiniRacer surface so the initializer becomes a no-op. This tunes the
# HOST app only (csim's own engine is rusty_racer, a separate platform)
# and applies to both drivers, so csim-vs-real comparisons stay fair.
# `CSIM_ALLOW_SINGLE_THREADED=1` restores upstream behaviour.
begin
  require 'mini_racer'
  if !ENV['CSIM_ALLOW_SINGLE_THREADED']
    module CsimSingleThreadedFilter
      def set_flags!(*args, **kw)
        args = args.reject {|a| a == :single_threaded }
        # Discourse's call is `set_flags!(:single_threaded)` — after
        # filtering, nothing remains; skip super so we don't re-init
        # MiniRacer::Platform with empty args (raises
        # PlatformAlreadyInitialized once any Context exists).
        super(*args, **kw) unless args.empty? && kw.empty?
      end
    end
    MiniRacer::Platform.singleton_class.prepend(CsimSingleThreadedFilter)
  end
rescue LoadError
end

# Rails 7.0's `active_support/logger_thread_safe_level.rb` references
# `Logger::Severity` at load time without `require 'logger'`. On
# Ruby 3.3+ that fails because Logger sits in a bundled gem now.
# Same story for other stdlib-extracted classes Rails 7.0 grew up
# expecting to be ambiently available.
%w[base64 bigdecimal csv drb logger mutex_m observer ostruct].each {|name| require name }

# Discourse / Forem declare `gem 'multi_json'` before `gem 'oj'`, so Bundler loads MultiJson first
# and it picks `:json_gem` as its default adapter. JsonGem's `JSON.dump(hash)` does NOT recurse into
# ActiveModelSerializer instances held as Hash values — it falls back to `.to_s` on unknown classes
# — and it turns a Ruby `Set` into an object rather than an array.
#
# This is a HOST-APP fix, so it runs for BOTH drivers. It used to sit below the driver guard, which
# meant the real-browser runs never got it: Discourse's `Site#admin_config_login_routes` is a `Set`,
# the SPA does `site.admin_config_login_routes.map(...)`, and Ember died with "is not a function"
# during render — every admin page came back EMPTY and the real run reported 452 failures of 2052.
# A baseline measured against that is worthless, which is how "the driver is 2x slower than Chrome"
# got into the record.
#
# Oj's `dump` defaults to `use_to_json: true`, so unknown classes route through AMS's `to_json` and
# nest correctly.
# RSpec is not loaded yet when RUBYOPT pulls this file in — the driver-gated block further down
# only reaches `RSpec.configure` because the requires between here and there bring it in. Load it
# explicitly so the hook registers for the REAL driver too.
begin
  require 'rspec/core'
rescue LoadError
  # A minitest host (Redmine) has no rspec-core; it has no MultiJson problem either.
end
RSpec.configure do |config|
  config.before(:suite) { MultiJson.use(:oj) if defined?(::MultiJson) && defined?(::Oj) }
end if defined?(::RSpec)

# The host-app boot fixes above (bundler/setup + stdlib-compat requires)
# must run for BOTH drivers — real Discourse/Forem need them for their own
# Rails boot, not just the simulated driver. Only the csim-driver-specific
# setup below is gated behind the driver check.
return unless ENV['CSIM_DRIVER'] == 'simulated'

require 'capybara/simulated'
require 'action_dispatch/system_test_case'

module CsimDrivenBy
  # Only intercept calls that asked for a real-browser driver. Hosts
  # like Forem set `driven_by :rack_test` for non-`:js` system specs
  # to keep them fast — rerouting those to `:simulated` boots the JS
  # runtime per spec for no benefit and surfaces JS execution paths
  # the tests never expected to fire (Datadog mocks, OmniAuth state,
  # etc.). Pass `:rack_test` straight through; only swap the real
  # browsers we'd substitute for.
  REAL_BROWSER_DRIVERS = %i[selenium selenium_chrome selenium_chrome_headless better_cuprite cuprite apparition playwright playwright_chrome playwright_mobile_chrome].freeze

  def driven_by(driver, **options, &block)
    return super unless REAL_BROWSER_DRIVERS.include?(driver)

    # Hosts wire chrome's download dir through cuprite-specific
    # options that we don't read; map common conventions onto
    # `Capybara.save_path` so attachment responses + JS-driven
    # `<a download>` clicks land where the host's helpers poll
    # for files. Set this *before* calling super so any synchronous
    # driver init happens against the right path.
    download_const = [
      ('::ApplicationSystemTestCase::DOWNLOADS_PATH' if defined?(::ApplicationSystemTestCase) && ::ApplicationSystemTestCase.const_defined?(:DOWNLOADS_PATH)),
      ('::DownloadHelpers::PATH'                    if defined?(::DownloadHelpers)             && ::DownloadHelpers.const_defined?(:PATH)),
    ].compact.first
    Capybara.save_path = Object.const_get(download_const).to_s if download_const

    # Discourse tags `describe "...", mobile: true` so its rails_helper
    # asks for `:playwright_mobile_chrome` — registered with both an
    # iPhone viewport and User-Agent. Both signals matter: viewport
    # drives `matchMedia('(max-width: 700px)')` branches; UA drives
    # Discourse's server-side rendering when `viewport_based_mobile_
    # mode = false`. Route to a separate `:simulated_mobile` driver
    # name (registered lazily below) so Capybara's session pool keeps
    # a dedicated Browser instance with sticky mobile defaults; if we
    # shared `:simulated` with desktop tests, the pool would reuse
    # whichever Driver was constructed first and the second-shape
    # test would see the wrong viewport.
    if (cfg = MOBILE_DRIVER_CONFIG[driver])
      Capybara::Simulated.ensure_mobile_driver_registered(cfg)
      return super(:simulated_mobile)
    end

    # The host declares the browser window its layout-dependent specs were
    # written against (`driven_by :cuprite, screen_size: [1400, 1024]`), and that
    # size is not decoration: Turbo's lazy `<turbo-frame>`s, DLoadMore's
    # IntersectionObserver sentinels and every scroll assertion are relative to
    # it. Dropping it ran those specs at the driver's own 1024x768 default, which
    # put an Avo tab's projects frame 24px BELOW the fold — so Turbo correctly
    # declined to load it and the pagination the spec looks for never rendered.
    # (Measured: Chrome puts the same frame at y=553 of a 1024-tall viewport, we
    # had it at y=792 of 768.)
    #
    # Seeded through the same slot the mobile shape uses. It is read-and-cleared when the driver is
    # CONSTRUCTED, which is what a host's `driven_by` precedes, so the size lands on the driver the
    # suite actually runs with. A host that asked for two different sizes in one process would keep
    # the first (Capybara caches a driver per name); none of the five does, and resizing a
    # already-built driver from here has no supported way to reach it — `Capybara` exposes no
    # session pool.
    if (size = normalized_screen_size(options))
      Capybara::Simulated.next_driver_viewport = size
    end

    # Important: return the result of `super` so rspec-rails'
    # `driven_by(...).tap(&:use)` can chain off the registration.
    super(:simulated)
  end

  def normalized_screen_size(options)
    size = options[:screen_size] || options[:window_size]
    return nil unless size.respond_to?(:to_a)

    w, h = size.to_a.map(&:to_i)
    (w.to_i > 0 && h.to_i > 0) ? [w, h] : nil
  end

  MOBILE_DRIVER_CONFIG = {
    playwright_mobile_chrome: {
      viewport:   [390, 664],
      user_agent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) ' \
                  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 ' \
                  'Mobile/15E148 Safari/604.1'
    }
  }.freeze
end
ActionDispatch::SystemTestCase.singleton_class.prepend(CsimDrivenBy)

module Capybara::Simulated
  class << self
    def ensure_mobile_driver_registered(cfg)
      return if @mobile_driver_registered
      @mobile_driver_registered = true
      ::Capybara.register_driver :simulated_mobile do |app|
        ::Capybara::Simulated::Driver.new(
          app,
          js_engine:  ENV['CSIM_JS_ENGINE']&.to_sym,
          viewport:   cfg[:viewport],
          user_agent: cfg[:user_agent]
        )
      end
    end
  end
end

# Expected-failure handling. Same YAML format as csim_minitest.rb's
# (`{test:, reason:[, engine:][, skip:]}`); `test:` matches against
# either RSpec's `example.full_description` or `example.location`.
require 'rspec/core'
require_relative 'csim_expected_failures'

CSIM_STRING_FAILURES, CSIM_REGEXP_FAILURES, _ =
  CsimExpectedFailures.load(ENV['CSIM_EXPECTED_FAILURES'], source: 'csim_rspec', extra_keys: ['skip'])

# `pending` (not `skip`): if the example unexpectedly passes, RSpec
# fails it as "FIXED — the test passed; remove `pending` from it",
# which is the signal to drop the entry from the YAML list. Mirrors
# csim_minitest.rb's "listed but passed → Assertion failure" path.
#
# Some entries set `skip: true` in the YAML. For those we use RSpec's
# `skip` (no body execution) instead — the example body would otherwise
# leak class-level state when it fails partway through (e.g. Avo's
# `Avo::Resources::X.with_temporary_items` blocks, which lack `ensure`,
# leave the resource configuration mutated for subsequent specs). Loses
# FIXED-detection on those entries; acceptable when the underlying
# failure is permanently out-of-scope (layout-engine dependence).
RSpec.configure do |config|
  config.before(:each) do |example|
    desc = example.full_description
    loc  = example.location
    matched = CSIM_STRING_FAILURES[desc] || CSIM_STRING_FAILURES[loc] ||
              CSIM_REGEXP_FAILURES.find {|entry| entry[:matcher].match?(desc) || entry[:matcher].match?(loc) }
    next unless matched
    if matched[:skip]
      # Discourse's `after(:each)` hook does `page.execute_script(...)`
      # even on skipped examples. Without an explicit current_driver
      # the hook constructs the host's configured driver (Playwright)
      # and crashes on the missing Chromium download. Pinning to
      # `:simulated` keeps the hook's lazy `page` reference on our
      # in-process driver.
      Capybara.current_driver = :simulated if Capybara.drivers.key?(:simulated)
      skip("expected failure (#{matched[:reason]})")
    else
      pending("expected failure (#{matched[:reason]})")
      # Discourse's `CapybaraTimeoutExtension` (rails_helper.rb) stashes
      # any Capybara default_max_wait_time exhaustion in
      # `example.metadata[:_capybara_timeout_exception]` during the body
      # and re-raises it in `after(:each)` if `example.exception.nil?`.
      # RSpec's `pending` consumes the body's expected failure → exception
      # becomes nil → the timeout extension fires and reports the test as
      # a genuine failure even though it correctly went pending. Tag the
      # metadata path that triggers the re-raise so listed-pending tests
      # stay clean in suite output.
      example.metadata[:_skip_capybara_timeout_recheck] = true
    end
  end

  # `prepend_after` so this runs BEFORE Discourse's
  # `CapybaraTimeoutExtension` re-raise hook (RSpec runs after-hooks in
  # reverse-definition order; Discourse's rails_helper.rb registers
  # theirs later than our RUBYOPT-loaded file, so theirs would
  # otherwise fire first).
  config.prepend_after(:each, type: :system) do |example|
    if example.metadata[:_skip_capybara_timeout_recheck]
      example.metadata.delete(:_capybara_timeout_exception)
    end
  end

  # Two Discourse class-level locale caches survive across examples in our
  # serial in-process run (a fresh-process CI never sees them):
  #
  # 1. `JsLocaleHelper.@loaded_translations` — the base YAML bundle that
  #    `output_MF` / `output_client_overrides` merge TranslationOverride
  #    values into.
  # 2. `ExtraLocalesController.@js_digests` — the compiled MF/overrides
  #    bundle DIGEST, keyed per (site, bundle, locale). This is the
  #    load-bearing one: the `/extra-locales/<digest>/<locale>/mf.js` URL the
  #    page embeds comes from this cache, and `show` marks the response
  #    `immutable_for(1.year)` when the digest matches. So a prior example
  #    pins digest_A (no override); a later example that `fab!`s a
  #    TranslationOverride re-emits the SAME digest_A URL, which our HTTP
  #    asset cache then serves immutably without ever re-running `output_MF`
  #    — the override never reaches the client (locale_spec messageformat
  #    overrides). Discourse clears this via a TranslationOverride after-save
  #    hook in production; the serial run needs the explicit clear.
  config.before(:each) do
    if Object.const_defined?(:JsLocaleHelper)
      Object.const_get(:JsLocaleHelper).clear_cache!
    end
    if Object.const_defined?(:ExtraLocalesController)
      Object.const_get(:ExtraLocalesController).clear_cache!(all_sites: true)
    end
  end

  # Per-example wall-clock cap. Capybara's own `default_max_wait_time`
  # bounds any single `find` / `has_?`, but a test that retries in a
  # tight loop (or hits a Ruby-side polling chain that doesn't yield
  # to Capybara's timeout) can stall the whole suite at one example.
  # Wrapping the example body in `Timeout::timeout` converts that
  # stall into a per-example failure so the run still completes.
  # `CSIM_EXAMPLE_TIMEOUT_S=0` disables.
  #
  # The limit is a STALL detector, not a performance budget, so it has to sit clear of the slowest
  # legitimate example. Avo's `code_field` ACE spec measures 121.4 s (`--profile`, timeout
  # disabled) against the old 120 s default — a 1 % margin that made it a coin flip: it failed run
  # alone and passed in the suite, at unrelated commits, and cost several review cycles to
  # attribute. 300 s restores the margin. The 121 s itself is the real finding — a real browser
  # does that example in seconds — and belongs in the driver's perf backlog, not here.
  # TEMP diagnosis instrument (2026-08-22, Discourse themes-file hang): when
  # CSIM_STALL_DUMP=<path> is set, a background thread watches the current
  # example's wall clock; past CSIM_STALL_DUMP_AFTER_S (default 120) it appends
  # every thread's Ruby backtrace plus the ActiveRecord lock owners
  # (ThreadLoadInterlockAwareMonitor exposes @owner) to <path>. A deadlocked
  # main thread can't report itself; this thread only needs a free GVL.
  if ENV['CSIM_STALL_DUMP']
    stall_after = (ENV['CSIM_STALL_DUMP_AFTER_S'] || '120').to_f
    $csim_example_started = nil
    $csim_example_desc    = nil
    config.around(:each) do |example|
      $csim_example_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      $csim_example_desc    = example.id
      begin
        example.run
      ensure
        $csim_example_started = nil
      end
    end
    Thread.new do
      Thread.current.name = 'csim-stall-dump'
      dumped_for = nil
      loop do
        sleep 15
        started = $csim_example_started
        next unless started
        next if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < stall_after
        next if dumped_for == started
        dumped_for = started
        # An IO failure (ENOSPC, EACCES) must not silently kill the diagnostics
        # thread for the rest of the run.
        begin
          File.open(ENV['CSIM_STALL_DUMP'], 'a') do |f|
            f.sync = true
            f.puts "########## STALL #{Time.now} example=#{$csim_example_desc}"
            # Owners FIRST, and only lock-free ivar reads: pool.connections takes
            # the pool monitor and joins the very deadlock being dumped.
            begin
              pool = ActiveRecord::Base.connection_pool
              pc   = pool.instance_variable_get(:@pinned_connection)
              f.puts "pool=#{pool.object_id} pinned_connection=#{pc&.object_id.inspect}"
              conns = (pool.instance_variable_get(:@connections) || []) | [pc].compact
              conns.each do |c|
                lk = c.instance_variable_get(:@lock)
                f.puts "conn=#{c.object_id} lease_owner=#{c.instance_variable_get(:@owner).inspect} lock=#{lk.class} lock_owner=#{lk.instance_variable_get(:@owner).inspect} lock_count=#{lk.instance_variable_get(:@count).inspect} mutex_locked=#{lk.instance_variable_get(:@mutex)&.locked?.inspect}"
              end
            rescue StandardError => e
              f.puts "AR introspection failed: #{e.class}: #{e.message}"
            end
            Thread.list.each do |t|
              f.puts "--- thread=#{t.object_id} name=#{t.name.inspect} status=#{t.status.inspect} #{t == Thread.main ? '(MAIN)' : ''}"
              (t.backtrace || ['(no ruby backtrace)']).each {|l| f.puts "    #{l}" }
            end
            # NATIVE stacks too: a main thread parked inside a native call (rusty's
            # without_gvl has no unblock function) shows only `Context#call` at the
            # Ruby level — the wedge's real location is in the C/Rust frames. The
            # boot-time prctl(PR_SET_PTRACER_ANY) above is what lets same-uid gdb
            # attach despite yama ptrace_scope=1.
            if system('command -v gdb >/dev/null 2>&1')
              f.puts '--- native stacks (gdb) ---'
              f.flush
              system("gdb -p #{Process.pid} -batch -ex 'set pagination off' -ex 'thread apply all bt 25' >> #{ENV['CSIM_STALL_DUMP']} 2>&1")
            end
            begin
              m = SiteSetting.provider ? SiteSetting.instance_variable_get(:@mutex) : nil
              f.puts "site_setting_mutex locked=#{m&.locked?.inspect}"
            rescue StandardError => e
              f.puts "SiteSetting introspection failed: #{e.class}: #{e.message}"
            end
            f.puts '########## END STALL DUMP'
          end
        rescue StandardError => e
          warn "csim-stall-dump failed: #{e.class}: #{e.message}"
        end
      end
    end
  end

  # Drain driver background app-requests BEFORE any other after-hook runs:
  # Discourse's cleanup hooks hit the DB through mini_sql (`DB.exec`), which
  # bypasses ActiveRecord's per-connection lock, so a still-running background
  # request (async <img> load, keepalive beacon) on the same pinned connection
  # can interleave on the raw PG socket and wedge it. The driver's own drain in
  # `reset!` runs at Capybara.reset_sessions! — AFTER these hooks — hence this
  # earlier pass. prepend_after runs ahead of all `after(:each)` hooks.
  config.prepend_after(:each) do
    sessions = Capybara.respond_to?(:session_pool, true) ? Capybara.send(:session_pool).values : [Capybara.current_session]
    sessions.each do |s|
      d = s&.driver
      d.drain_background_requests if d.respond_to?(:drain_background_requests)
    rescue StandardError
      nil
    end
  end

  require 'timeout'
  EXAMPLE_TIMEOUT_S = (ENV['CSIM_EXAMPLE_TIMEOUT_S'] || '300').to_i
  if EXAMPLE_TIMEOUT_S > 0
    # Timeout.timeout delivers via Thread#raise, which code blocked inside
    # `Thread.handle_interrupt(Exception => :never)` defers indefinitely —
    # ActiveRecord acquires its connection locks exactly that way, so an example
    # wedged there shrugs off the timeout (and SIGTERM, which Ruby delivers
    # through the same interrupt checkpoint) and hangs the whole run. Seen live
    # on Discourse 2026-08-22: a lock pile-up behind a leftover driver background
    # thread parked the suite at 0% CPU, kill -9 only. The escalation thread
    # turns that into a diagnosable crash: one grace period after the deadline it
    # dumps every thread's backtrace and hard-kills the process. SIGKILL over
    # `Process.exit!` not for strength (measured: both work from a background
    # thread while main is masked; both need this thread to get the GVL — a C
    # call HOLDING the GVL would defeat either) but because KILL skips at_exit /
    # ensure work that could itself wedge. The grace has to clear a legitimate
    # post-timeout teardown (screenshot capture, app after-hooks, per-session
    # driver drains), not just scheduling noise — hence minutes, not seconds.
    escalation_grace = 120
    example_deadline = nil
    config.around(:each) do |example|
      example_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + EXAMPLE_TIMEOUT_S
      begin
        Timeout.timeout(EXAMPLE_TIMEOUT_S, nil, "csim example timeout after #{EXAMPLE_TIMEOUT_S}s") do
          example.run
        end
      ensure
        example_deadline = nil
      end
    end
    Thread.new do
      Thread.current.name = 'csim-timeout-escalation'
      loop do
        sleep 10
        deadline = example_deadline
        next unless deadline
        overdue = Process.clock_gettime(Process::CLOCK_MONOTONIC) - deadline
        next unless overdue > escalation_grace
        # The kill must happen even if the diagnostics raise (EPIPE on a dead
        # stderr, a backtrace that won't format) — a silent watcher death would
        # restore the undetectable hang this thread exists to prevent.
        begin
          $stderr.puts "csim: example timeout could not be delivered #{overdue.round}s past deadline (main thread under handle_interrupt(Exception => :never), or parked in a native call with no unblock function?) — dumping threads and killing the process. Check for orphaned child processes (minio, foreman) afterwards: after(:suite) cleanup will NOT run."
          Thread.list.each do |t|
            $stderr.puts "--- thread=#{t.object_id} name=#{t.name.inspect} status=#{t.status.inspect} #{t == Thread.main ? '(MAIN)' : ''}"
            (t.backtrace || ['(no ruby backtrace)']).each {|l| $stderr.puts "    #{l}" }
          end
          $stderr.flush
        rescue StandardError
          nil
        end
        Process.kill('KILL', Process.pid)
      end
    end
  end

  # Mastodon's `spec/support/capybara.rb` sets
  # `Capybara.javascript_driver = :playwright` at load time, and the
  # first `before(:each, :js)` hook that touches
  # `Capybara.current_session.driver` instantiates Playwright (which
  # explodes without the Chrome download). Force `:simulated` after
  # the host's RSpec config has finished loading so any auto-driver
  # selection on `:js`-tagged specs picks our driver, not the host's
  # configured real-browser one.
  config.before(:suite) do
    require 'capybara'
    Capybara.javascript_driver = :simulated

    # `capybara/rails` (required by Discourse's rails_helper.rb)
    # assigns `Capybara.app` to a `Rack::URLMap` (the return value of
    # `Rack::Builder#to_app`). Rails' `system_test_case.rb` re-runs
    # `start_application` to set it back to a `Rack::Builder` — but
    # only on first load, and we load `system_test_case` ourselves
    # early (to prepend CsimDrivenBy), so the second load is a no-op
    # and Capybara.app stays as the URLMap. Discourse's
    # `set_subfolder` helper calls `Capybara.app.map(...)`, which only
    # works on a Builder. Re-run start_application here so the helper
    # works under simulated like it does under real-browser CI.
    if defined?(::ActionDispatch::SystemTestCase) && Capybara.app.is_a?(::Rack::URLMap)
      ::ActionDispatch::SystemTestCase.start_application
    end

    # Discourse's spec/support/system_helpers.rb defines `locator(sel)`
    # as a thin pass-through to `page.driver.with_playwright_page { |p|
    # p.locator(sel) }`. Our driver's `with_playwright_page` is a
    # graceful no-op (no yield), so the helper returns nil — and the
    # select-kit page object then dereferences `expanded_component
    # .locator(".select-kit-row[...]").click`, hitting `NoMethodError
    # 'locator' for nil`. Re-implement the helper against Capybara so
    # the same Playwright-shaped call sites work under the simulated
    # driver. Only the lazy `Locator` surface select-kit / form-kit /
    # date-picker call (`click`, `fill`, `first`, `count`, `press`,
    # `text_content`, chained `locator(child)`) is shimmed — pages that
    # reach for CDP / context APIs still take the `with_playwright_page
    # = no-op` path and skip out.
    if defined?(::SystemHelpers)
      Capybara::Simulated.send(:remove_const, :Locator) if Capybara::Simulated.const_defined?(:Locator, false)
      Capybara::Simulated.const_set(:Locator, Class.new {
        def initialize(scope, selector)
          @scope    = scope
          @selector = selector
        end

        def locator(child)      = self.class.new(self, child)
        def click               = node.click
        def fill(value)         = node.set(value)
        def hover               = node.hover
        def first               = self
        def count               = nodes.count
        def press(key)          = node.send_keys(translate_key(key))
        def text_content        = node.text
        def visible?            = node.visible?
        def disabled?           = node.disabled?
        def get_attribute(name) = node[name]
        def all                 = nodes

        private

        def node
          base.find(@selector, visible: :all)
        end

        def nodes
          base.all(@selector, visible: :all)
        end

        def base
          @scope.is_a?(self.class) ? @scope.send(:node) : @scope
        end

        def translate_key(key)
          case key.to_s
          when 'Escape' then :escape
          when 'Enter'  then :enter
          when 'Tab'    then :tab
          when 'Space'  then :space
          when 'ArrowDown'  then :down
          when 'ArrowUp'    then :up
          when 'ArrowLeft'  then :left
          when 'ArrowRight' then :right
          when 'Backspace'  then :backspace
          else key.to_s
          end
        end
      })

      # Playwright `Locator#all` returns an array of single-element
      # locators; each supports `get_attribute(name)` / `text_content`
      # / `click`. Capybara's `Node::Element#all` already returns an
      # array — alias the two read accessors so Discourse's
      # `.all.map { |row| row.get_attribute(...) }` pattern works
      # without further wrapping.
      Capybara::Node::Element.class_eval do
        alias_method :get_attribute, :[] unless method_defined?(:get_attribute)
        alias_method :text_content,  :text unless method_defined?(:text_content)
      end

      ::SystemHelpers.module_eval do
        remove_method(:locator) if instance_method(:locator).owner == self rescue nil
        define_method(:locator) do |selector, scope = nil|
          Capybara::Simulated::Locator.new(scope || page, selector)
        end
      end

      # `PageObjects::CDP#with_slow_upload` uses Playwright CDP to
      # throttle the network so the test can observe the in-progress
      # upload UI. We have no real network — park the upload XHR's
      # response side instead, so `#file-uploading` stays in the DOM
      # long enough for the assertion to catch it.
      #
      # `with_virtual_authenticator` (and the CDP `WebAuthn.*` messages
      # it threads into the block) route into the Browser-side
      # WebauthnState — ECDSA P-256 keys, COSE/CBOR-encoded
      # attestation, ECDSA-signed assertion — so security-key /
      # passkey flows can run without a real WebAuthn-capable browser.
      if defined?(::PageObjects::CDP)
        cdp_shim = Module.new {
          def with_slow_upload
            page.execute_script('globalThis.__csimSlowUploadActive = true')
            begin
              yield
            ensure
              page.execute_script('globalThis.__csimSlowUploadActive = false; globalThis.__csimDrainSlowUploads();')
            end
          end

          def with_network_disconnected
            page.execute_script('__csimSetOnline(false)')
            begin
              yield
            ensure
              page.execute_script('__csimSetOnline(true)')
            end
          end
        }
        ::PageObjects::CDP.prepend(cdp_shim)
      end

      if defined?(::SystemHelpers)
        webauthn_shim = Module.new {
          def with_virtual_authenticator(options = {})
            opts_json = ::JSON.dump(options)
            handle = page.evaluate_script("__csimWebauthnAddVirtualAuthenticator(#{opts_json})")
            begin
              yield(Capybara::Simulated::CdpClientShim.new(page), handle)
            ensure
              page.execute_script("__csimWebauthnRemoveVirtualAuthenticator(#{::JSON.dump(handle)})")
            end
          end
        }
        ::SystemHelpers.prepend(webauthn_shim)
      end

      # Stand-in for the Playwright CDPClient that
      # `cdp.with_virtual_authenticator` yields. Routes the
      # `WebAuthn.*` messages tests send to the Browser-side
      # `WebauthnState`; non-WebAuthn methods are a quiet no-op so
      # unrelated CDP probes don't crash.
      Capybara::Simulated.send(:remove_const, :CdpClientShim) if Capybara::Simulated.const_defined?(:CdpClientShim, false)
      Capybara::Simulated.const_set(:CdpClientShim, Class.new {
        def initialize(page) = (@page = page)

        def send_message(method, params: nil)
          h = (params || {}).each_with_object({}) {|(k, v), o| o[k.to_s] = v }
          # Non-WebAuthn CDP messages are quiet no-ops — apps probe
          # for unrelated capabilities (Network.enable, Page.*, …)
          # and Discourse's CDP helpers don't care about the reply.
          return nil unless method.to_s.start_with?('WebAuthn.')

          case method.to_s
          when 'WebAuthn.enable', 'WebAuthn.disable',
               'WebAuthn.setAutomaticPresenceSimulation'
            nil
          when 'WebAuthn.addCredential'
            @page.execute_script(
              "__csimWebauthnAddCredential(#{::JSON.dump(h['authenticatorId'])}, #{::JSON.dump(h['credential'])})"
            )
          when 'WebAuthn.removeCredential'
            @page.execute_script(
              "__csimWebauthnRemoveCredential(#{::JSON.dump(h['authenticatorId'])}, #{::JSON.dump(h['credentialId'])})"
            )
          when 'WebAuthn.getCredentials'
            return {'credentials' => @page.evaluate_script("__csimWebauthnGetCredentials(#{::JSON.dump(h['authenticatorId'])})")}
          when 'WebAuthn.setUserVerified'
            @page.execute_script(
              "__csimWebauthnSetUserVerified(#{::JSON.dump(h['authenticatorId'])}, #{::JSON.dump(!!h['isUserVerified'])})"
            )
          when 'WebAuthn.clearCredentials'
            (@page.evaluate_script("__csimWebauthnGetCredentials(#{::JSON.dump(h['authenticatorId'])})") || []).each do |c|
              @page.execute_script(
                "__csimWebauthnRemoveCredential(#{::JSON.dump(h['authenticatorId'])}, #{::JSON.dump(c['credentialId'])})"
              )
            end
          else
            raise ArgumentError, "Unknown WebAuthn CDP method: #{method}"
          end
          nil
        end
      })
    end
  end
end

# Auto-trace file output (opt in with `CSIM_TRACE_DIR=/path/to/dir`).
# The gem's RSpec integration reads that env var and installs the
# per-example persistence hook itself — this used to be hand-rolled here
# and called a `Driver.current` that never existed. `rescue LoadError`
# tolerates an older capybara-simulated that predates the integration
# file (its absence just means no auto-trace, as before).
begin
  require 'capybara/simulated/rspec'
rescue LoadError
  # capybara/simulated/rspec not available in this gem version
end
