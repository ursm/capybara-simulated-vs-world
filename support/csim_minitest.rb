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

# `CSIM_JS_ENGINE={quickjs,v8,none}` picks the runtime; unset = auto-
# detect (quickjs preferred, then v8, then none).
js_engine = ENV['CSIM_JS_ENGINE']&.to_sym

# `CSIM_QUICKJS_FEATURES=intl,file,…` re-registers `:simulated` with
# extra Quickjs polyfills layered onto the gem's lean default. See
# csim_rspec.rb for the rationale (Avo / Forem opt-ins). Features only
# apply to the QuickJS runtime — V8 / none ignore the array.
features =
  if (extra = ENV['CSIM_QUICKJS_FEATURES']) && !extra.empty? && (js_engine.nil? || js_engine == :quickjs)
    require 'quickjs'
    extra.split(',').map {|n| Quickjs.const_get("POLYFILL_#{n.strip.upcase}") }
  else
    []
  end

if !features.empty? || js_engine
  Capybara.register_driver :simulated do |app|
    Capybara::Simulated::Driver.new(app, features: features, js_engine: js_engine)
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

# Expected-failure handling. The list is YAML; each entry is a hash
# of `test:` (exact `Class#method` string or Regexp) plus `reason:`
# (verbatim text surfaced in the skip message).
#
#   - test: "Class#method"
#     reason: "why this is parked"
#   - test: !ruby/regexp /Class#test_pattern/
#     reason: "why this whole family is parked"
list_path = ENV['CSIM_EXPECTED_FAILURES']
return unless list_path && File.exist?(list_path)

require 'yaml'
require 'minitest'

CSIM_EXPECTED_FAILURES = (YAML.load_file(list_path, permitted_classes: [Regexp]) || []).map {|entry|
  raise "csim_minitest: expected-failure entry must be a hash, got #{entry.inspect}" unless entry.is_a?(Hash)
  h = entry.transform_keys(&:to_s)
  {matcher: h.fetch('test'), reason: h.fetch('reason')}
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

      if result.failures.any? {|f| !f.is_a?(Minitest::Skip) }
        result.failures.clear
        result.failures << Minitest::Skip.new("expected failure (#{matched[:reason]})")
      elsif result.passed?
        result.failures << Minitest::Assertion.new(
          "listed in expected_failures but passed — drop it from the list:\n  #{matched[:matcher].inspect}"
        )
      end
    end
  end
end

Minitest::Test.prepend(CsimExpectedFailures)
