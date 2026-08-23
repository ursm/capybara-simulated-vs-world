# Shared YAML expected-failures loader for `csim_rspec.rb` and
# `csim_minitest.rb` (an entry can also be a per-test driver annotation
# rather than a failure — csim_rspec's `fresh_http_cache:`). Reads the
# list at `CSIM_EXPECTED_FAILURES`,
# applies the `engine:` filter (Capybara::Simulated::JS_ENGINES),
# splits matchers into a String-keyed hash (O(1) per-spec hit) and a
# Regexp-only array (scanned linearly; few entries).
#
# Per-framework "what to do on match" stays in each caller because
# RSpec and Minitest pend differently (pending in a before(:each)
# hook vs post-run reclassification of failures into skips).

require 'yaml'

module CsimExpectedFailures
  module_function

  # Returns `[string_hash, regexp_array, count]`.
  # - string_hash:  matcher String → entry Hash
  # - regexp_array: entries whose matcher is a Regexp
  # - count:        total entries (post-engine-filter); 0 if list_path
  #                 is nil / missing
  #
  # `extra_keys` lets callers grab framework-specific fields off each
  # entry (e.g. RSpec's `skip:` toggle for "body-execution leaks state
  # so pend with skip semantics instead").
  def load(list_path, source:, extra_keys: [])
    return [{}, [], 0] unless list_path && File.exist?(list_path)

    yaml = parse_yaml(list_path)
    known_engines = Capybara::Simulated::JS_ENGINES.map(&:to_s)
    active_engine = ENV.fetch('CSIM_JS_ENGINE', 'v8')

    string_map = {}
    regexp_arr = []
    count = 0

    (yaml || []).each {|entry|
      raise "#{source}: expected-failure entry must be a hash, got #{entry.inspect}" unless entry.is_a?(Hash)
      h = entry.transform_keys(&:to_s)
      if (eng = h['engine']) && !known_engines.include?(eng)
        raise "#{source}: unknown engine: #{eng.inspect} (expected one of #{known_engines.inspect}); typo?"
      end
      next if h['engine'] && h['engine'] != active_engine

      unknown = h.keys - %w[test reason engine] - extra_keys.map(&:to_s)
      raise "#{source}: unknown key(s) #{unknown.inspect} on #{h['test'].inspect}; typo, or a key this runner doesn't honour?" unless unknown.empty?
      rec = {matcher: h.fetch('test'), reason: h.fetch('reason')}
      extra_keys.each {|k| rec[k.to_sym] = h.fetch(k.to_s, false) }
      case rec[:matcher]
      when String then string_map[rec[:matcher]] = rec
      when Regexp then regexp_arr << rec
      else raise "#{source}: matcher must be String or Regexp, got #{rec[:matcher].inspect}"
      end
      count += 1
    }

    [string_map.freeze, regexp_arr.freeze, count]
  end

  # Avo's CI gemfile (Appraisal-generated) drags in psych 3.3.4, which
  # predates the `permitted_classes:` kwarg on `YAML.load_file`. Fall
  # back to `unsafe_load_file` there. Our skip lists are repo-tracked
  # so the unsafe path is fine.
  def self.parse_yaml(path)
    YAML.load_file(path, permitted_classes: [Regexp])
  rescue ArgumentError
    YAML.unsafe_load_file(path)
  end
end
