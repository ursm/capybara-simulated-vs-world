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
  REAL_BROWSER_DRIVERS = %i[selenium selenium_chrome selenium_chrome_headless better_cuprite cuprite apparition].freeze

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

    # Important: return the result of `super` so rspec-rails'
    # `driven_by(...).tap(&:use)` can chain off the registration.
    super(:simulated)
  end
end
ActionDispatch::SystemTestCase.singleton_class.prepend(CsimDrivenBy)

# Expected-failure handling. Same YAML format as csim_minitest.rb's
# (`{test:, reason:}`); `test:` matches against either RSpec's
# `example.full_description` or `example.location`.
list_path = ENV['CSIM_EXPECTED_FAILURES']
return unless list_path && File.exist?(list_path)

require 'yaml'
require 'rspec/core'

# Avo's CI gemfile (Appraisal-generated) drags in psych 3.3.4, which
# predates the `permitted_classes:` kwarg on `YAML.load_file`. Fall back
# to `unsafe_load_file` there. Our skip lists are repo-tracked so the
# unsafe path is fine.
yaml_loaded =
  begin
    YAML.load_file(list_path, permitted_classes: [Regexp])
  rescue ArgumentError
    YAML.unsafe_load_file(list_path)
  end

CSIM_EXPECTED_FAILURES = (yaml_loaded || []).map {|entry|
  raise "csim_rspec: expected-failure entry must be a hash, got #{entry.inspect}" unless entry.is_a?(Hash)
  h = entry.transform_keys(&:to_s)
  {matcher: h.fetch('test'), reason: h.fetch('reason'), skip: h.fetch('skip', false)}
}.freeze

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
    matched = CSIM_EXPECTED_FAILURES.find {|entry|
      m = entry[:matcher]
      case m
      when Regexp then m.match?(desc) || m.match?(loc)
      when String then m == desc || m == loc
      end
    }
    next unless matched
    if matched[:skip]
      skip("expected failure (#{matched[:reason]})")
    else
      pending("expected failure (#{matched[:reason]})")
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
