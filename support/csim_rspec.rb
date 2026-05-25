# Preloaded via `RUBYOPT='-r<this-file>'` for RSpec-based suites
# (Forem). Mirror of `csim_minitest.rb` with two responsibilities:
#
# 1. Override `ActionDispatch::SystemTestCase.driven_by` so any
#    `driven_by :anything` from the host's RSpec hooks routes to
#    `:simulated` when `CSIM_DRIVER=simulated` is set.
# 2. Skip examples whose `<class>#<method>`-shaped description matches
#    an entry in the expected-failures list at `CSIM_EXPECTED_FAILURES`.

return unless ENV['CSIM_DRIVER'] == 'simulated'

# Bundler activates the gem set BEFORE exec'ing ruby, so $LOAD_PATH is
# already wired up by the time RUBYOPT runs us — but the released
# capybara-simulated 0.0.7 vs the local path version both ship a
# version.rb with the same constant, and requiring without a fresh
# Bundler.require chain double-loads the path-version on top of the
# released-gem one. Forcing `bundler/setup` first locks in the
# Gemfile-resolved version (the local path) before the require.
require 'bundler/setup'

# Rails 7.0's `active_support/logger_thread_safe_level.rb` references
# `Logger::Severity` at load time without `require 'logger'`. On
# Ruby 3.3+ that fails because Logger sits in a bundled gem now.
# Same story for other stdlib-extracted classes Rails 7.0 grew up
# expecting to be ambiently available.
%w[base64 bigdecimal csv drb logger mutex_m observer ostruct].each {|name| require name }

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

    # Important: return the result of `super` so rspec-rails'
    # `driven_by(...).tap(&:use)` can chain off the registration.
    super(:simulated)
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
    end
  end

  # Per-example wall-clock cap. Capybara's own `default_max_wait_time`
  # bounds any single `find` / `has_?`, but a test that retries in a
  # tight loop (or hits a Ruby-side polling chain that doesn't yield
  # to Capybara's timeout) can stall the whole suite at one example.
  # Wrapping the example body in `Timeout::timeout` converts that
  # stall into a per-example failure so the run still completes.
  # `CSIM_EXAMPLE_TIMEOUT_S=0` disables; default 120 s is well above
  # the slowest legitimate Discourse system spec.
  require 'timeout'
  EXAMPLE_TIMEOUT_S = (ENV['CSIM_EXAMPLE_TIMEOUT_S'] || '120').to_i
  if EXAMPLE_TIMEOUT_S > 0
    config.around(:each) do |example|
      Timeout.timeout(EXAMPLE_TIMEOUT_S, nil, "csim example timeout after #{EXAMPLE_TIMEOUT_S}s") do
        example.run
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

    # Discourse / Forem declare `gem 'multi_json'` before `gem 'oj'`,
    # so Bundler loads MultiJson first and it picks `:json_gem` as its
    # default adapter. JsonGem's `JSON.dump(hash)` does NOT recurse
    # into ActiveModelSerializer instances held as Hash values — it
    # falls back to `.to_s` on unknown classes — so Discourse's
    # preloaded `currentUser.sidebar_sections[].links` ends up as
    # `["#<SidebarUrlSerializer:0x...>", ...]` and the community
    # sidebar section renders empty. Real-browser CI doesn't hit this
    # because Bundler-with-Bootsnap warms the gem set differently.
    #
    # Force the Oj adapter when both gems are loaded — its `dump`
    # defaults to `use_to_json: true`, so unknown classes route
    # through AMS's `to_json` and nest correctly.
    MultiJson.use(:oj) if defined?(::MultiJson) && defined?(::Oj)

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
        slow_upload_shim = Module.new {
          def with_slow_upload
            page.execute_script('globalThis.__csimSlowUploadActive = true')
            begin
              yield
            ensure
              page.execute_script('globalThis.__csimSlowUploadActive = false; globalThis.__csimDrainSlowUploads();')
            end
          end
        }
        ::PageObjects::CDP.prepend(slow_upload_shim)
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

# Optional auto-trace hook. With `CSIM_TRACE_DIR=/path/to/dir`, the
# driver auto-starts a trace on the first action of each system
# example (`Browser#record_action`) and the after-hook below persists
# it. Suites that want finer control leave the env var unset and call
# `driver.start_tracing(...)` / `stop_tracing(...)` themselves — see
# `Capybara::Simulated::Driver#start_tracing`.
if (trace_dir = ENV['CSIM_TRACE_DIR']) && !trace_dir.empty?
  require 'fileutils'
  FileUtils.mkdir_p(trace_dir)

  RSpec.configure do |config|
    config.prepend_after(:each, type: :system) do |example|
      drv = Capybara::Simulated::Driver.current
      next unless drv&.tracing?
      drv.current_trace.metadata.merge!(
        title:     example.full_description,
        file:      example.location,
        outcome:   example.exception ? 'failed' : 'passed',
        exception: example.exception&.message
      )
      slug = example.full_description.gsub(/[^A-Za-z0-9._-]+/, '_')[0, 200]
      drv.stop_tracing(path: File.join(trace_dir, "#{slug}.json"))
    end
  end
end
