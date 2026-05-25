# Preloaded via `RUBYOPT='-r<this-file>'`. Two responsibilities:
#
# 1. Override `ActionDispatch::SystemTestCase.driven_by` to route to
#    `:simulated` when CSIM_DRIVER selects it, without patching the
#    host app's `application_system_test_case.rb`.
# 2. Skip examples whose `<class>#<method>` matches an entry in the
#    expected-failures list at `CSIM_EXPECTED_FAILURES`. Track
#    actually-passing skips and fail the run when the list grows
#    stale.

return unless ENV['CSIM_DRIVER'] == 'simulated'

# Bundler activates the gem set BEFORE exec'ing ruby, so $LOAD_PATH is
# already wired up by the time RUBYOPT runs us — but the released
# capybara-simulated 0.0.7 vs the local path version both ship a
# version.rb with the same constant, and requiring without a fresh
# Bundler.require chain double-loads the path-version on top of the
# released-gem one. Forcing `bundler/setup` first locks in the
# Gemfile-resolved version (the local path) before the require.
require 'bundler/setup'
require 'capybara/simulated'
require 'action_dispatch/system_test_case'

# Capybara polls find/has_? via `synchronize`, sleeping
# `default_retry_interval` (10 ms) between retries when `driver.wait?`
# is true. Our driver is deterministic — every observable side effect
# from the previous line has already settled — so the sleep is only
# useful when a *real* timer is ticking down (setTimeout(N>0) waiting
# for content to appear). `CSIM_RETRY_INTERVAL=N` overrides for ad-hoc
# perf experiments; 0.001 keeps virtual-clock advance per tick small
# enough that setTimeout-bound assertions still settle while cutting
# the busy-wait cost on bad-input finds (typos that never resolve).
if (n = ENV['CSIM_RETRY_INTERVAL'])
  Capybara.default_retry_interval = Float(n)
end

# `PARALLEL_WORKERS=N PARALLEL_WITH=processes|threads` overrides the
# host's `parallelize(workers: …, with: …)` setting. The host's
# `test_helper.rb` (Redmine pins `workers: 1`) runs after this file,
# so we hook the class method to substitute our values whenever it's
# called. capybara-simulated is in-process, so `with: :threads` shares
# the JS runtime + DB connection pool across worker threads — which is
# exactly the configuration Selenium-based suites can't run.
if ENV['PARALLEL_WORKERS']
  workers = ENV['PARALLEL_WORKERS'].to_i
  mode    = (ENV['PARALLEL_WITH'] || 'threads').to_sym
  module CsimParallelize
    def parallelize(workers: nil, with: nil)
      super(workers: ::ENV['PARALLEL_WORKERS'].to_i,
            with:    (::ENV['PARALLEL_WITH'] || 'threads').to_sym)
    end
  end
  ActiveSupport::TestCase.singleton_class.prepend(CsimParallelize)
  warn "[csim] parallelize override: workers=#{workers}, with=#{mode}"

  # In `with: :threads` mode Capybara's session pool is global, keyed
  # by [driver, session_name, app]. Worker threads all hit the
  # default session → same Session → same Driver → same Browser →
  # cross-thread cookie / navigation contamination. Give each worker
  # thread its own `Capybara.session_name`; the pool then returns
  # distinct Session instances and the Browsers stay isolated.
  if mode == :threads && defined?(::ActionDispatch::SystemTestCase)
    module CsimThreadSession
      def before_setup
        ::Capybara.session_name = "csim-thread-#{::Thread.current.object_id}"
        super
      end
    end
    ::ActionDispatch::SystemTestCase.prepend(CsimThreadSession)
  end
end

module CsimDrivenBy
  def driven_by(_driver, **_options, &_block)
    super(:simulated)
    # Hosts often configure the real-browser download directory through
    # driver options that the simulated driver doesn't read. Mirror it
    # onto `Capybara.save_path` so attachment responses land where the
    # test is looking. Redmine uses `ApplicationSystemTestCase::DOWNLOADS_PATH`.
    if defined?(::ApplicationSystemTestCase) && ::ApplicationSystemTestCase.const_defined?(:DOWNLOADS_PATH)
      Capybara.save_path = ::ApplicationSystemTestCase::DOWNLOADS_PATH
    end
  end
end
ActionDispatch::SystemTestCase.singleton_class.prepend(CsimDrivenBy)

# Expected-failure handling. Same YAML format as csim_rspec.rb's
# (`{test:, reason:[, engine:]}`); `test:` is an exact `Class#method`
# string or a Regexp matched against the same.
require 'minitest'
require_relative 'csim_expected_failures'

CSIM_STRING_FAILURES, CSIM_REGEXP_FAILURES, _ =
  CsimExpectedFailures.load(ENV['CSIM_EXPECTED_FAILURES'], source: 'csim_minitest')

# Run each test through, then re-classify the result against the
# expected-failure list. Listed failure → swap to Skip ("expected
# failure"). Listed pass → swap to a synthetic failure so the run
# is visibly not-green ("listed but passed — update the list"). Real
# pass / real failure pass through unchanged.
module CsimMinitestPend
  def run
    super.tap do |result|
      desc = "#{self.class.name}##{name}"
      matched = CSIM_STRING_FAILURES[desc] ||
                CSIM_REGEXP_FAILURES.find {|entry| entry[:matcher].match?(desc) }
      next unless matched

      if result.failures.any? {|f| !f.is_a?(Minitest::Skip) }
        result.failures.clear
        result.failures << Minitest::Skip.new("expected failure (#{matched[:reason]})")
      elsif result.passed?
        ex = Minitest::Assertion.new(
          "listed in expected_failures but passed — drop it from the list:\n  #{matched[:matcher].inspect}"
        )
        # Synthetic failures need an explicit backtrace — Rails'
        # BacktraceCleaner#filter_backtrace nil-crashes inside
        # Minitest::Result#to_s otherwise, masking which test was
        # unblocked.
        ex.set_backtrace(caller)
        result.failures << ex
      end
    end
  end
end

Minitest::Test.prepend(CsimMinitestPend)
