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

require 'capybara/simulated'
require 'action_dispatch/system_test_case'

module CsimDrivenBy
  def driven_by(_driver, **_options, &_block)
    super(:simulated)
  end
end
ActionDispatch::SystemTestCase.singleton_class.prepend(CsimDrivenBy)

# Expected-failure handling. The list is YAML; each entry is either
# the exact `Class#method` string the test runner prints, or a Regexp
# matched against it.
list_path = ENV['CSIM_EXPECTED_FAILURES']
return unless list_path && File.exist?(list_path)

require 'yaml'
require 'minitest'

CSIM_EXPECTED_FAILURES = YAML.load_file(list_path, permitted_classes: [Regexp]).freeze

# Run each test through, then re-classify the result against the
# expected-failure list. Listed failure → swap to Skip ("expected
# failure"). Listed pass → swap to a synthetic failure so the run
# is visibly not-green ("listed but passed — update the list"). Real
# pass / real failure pass through unchanged.
module CsimExpectedFailures
  def run
    super.tap do |result|
      desc = "#{self.class.name}##{name}"
      matched = CSIM_EXPECTED_FAILURES.find do |entry|
        case entry
        when Regexp then entry.match?(desc)
        when String then entry == desc
        end
      end
      next unless matched

      if result.failures.any? { |f| !f.is_a?(Minitest::Skip) }
        result.failures.clear
        result.failures << Minitest::Skip.new("expected failure: #{matched.inspect}")
      elsif result.passed?
        result.failures << Minitest::Assertion.new(
          "listed in expected_failures but passed — drop it from the list:\n  #{matched.inspect}"
        )
      end
    end
  end
end

Minitest::Test.prepend(CsimExpectedFailures)
