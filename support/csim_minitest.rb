# Preloaded via `RUBYOPT='-r<this-file>'`. Two responsibilities:
#
# 1. Override `ActionDispatch::SystemTestCase.driven_by` to route to
#    `:simulated` when `CSIM_DRIVER=simulated` is set, without
#    patching the host app's `application_system_test_case.rb`.
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

# Expected-failure handling. The list is YAML; each entry is one of:
#
#   - "Class#method"                          # exact match
#   - !ruby/regexp /Class#test_pattern/       # regex match
#   - {test: "Class#method", reason: "..."}   # exact match + skip reason
#   - {test: !ruby/regexp /.../, reason: ...} # regex match + skip reason
#
# String / Regexp forms get a generic "expected failure" reason in the
# skip message; hash forms surface the reason verbatim so test output
# tells you why each one is parked.
list_path = ENV['CSIM_EXPECTED_FAILURES']
return unless list_path && File.exist?(list_path)

require 'yaml'
require 'minitest'

CSIM_EXPECTED_FAILURES = (YAML.load_file(list_path, permitted_classes: [Regexp]) || []).map {|entry|
  case entry
  when String, Regexp
    {matcher: entry, reason: nil}
  when Hash
    h = entry.transform_keys(&:to_s)
    {matcher: h.fetch('test'), reason: h['reason']}
  else
    raise "csim_minitest: unsupported expected-failure entry #{entry.inspect}"
  end
}.freeze

# Run each test through, then re-classify the result against the
# expected-failure list. Listed failure → swap to Skip ("expected
# failure"). Listed pass → swap to a synthetic failure so the run
# is visibly not-green ("listed but passed — update the list"). Real
# pass / real failure pass through unchanged.
module CsimExpectedFailures
  def run
    super.tap do |result|
      desc = "#{self.class.name}##{name}"
      matched = CSIM_EXPECTED_FAILURES.find {|entry|
        m = entry[:matcher]
        case m
        when Regexp then m.match?(desc)
        when String then m == desc
        end
      }
      next unless matched

      label = matched[:reason] ? "expected failure (#{matched[:reason]})" : 'expected failure'

      if result.failures.any? {|f| !f.is_a?(Minitest::Skip) }
        result.failures.clear
        result.failures << Minitest::Skip.new(label)
      elsif result.passed?
        result.failures << Minitest::Assertion.new(
          "listed in expected_failures but passed — drop it from the list:\n  #{matched[:matcher].inspect}"
        )
      end
    end
  end
end

Minitest::Test.prepend(CsimExpectedFailures)
