# Sum every Rack request's wall time across the suite, so driver-vs-driver
# comparisons can subtract the shared Rails-app cost.
#
# Wraps the rack app at three boundaries so both drivers see the timer:
#  - `Capybara::Config#app=`   — when the host's spec_helper assigns it
#  - `Capybara::Server#new`    — Cuprite / Puma path
#  - `Capybara::Simulated::Driver#new` — Simulated path (bypasses Server)
# The middleware is idempotent (no-op if already wrapped) so any path that
# touches the app multiple times only counts once.

# Lock in Bundler-resolved gems before requiring capybara. Without this,
# under `CSIM_DRIVER=real` (where csim_rspec/csim_minitest return early
# and skip their own `require 'bundler/setup'`), `require 'capybara'`
# can grab a system-installed copy whose classes differ from the
# bundle's — our prepends then land on the wrong constant and the
# middleware never fires.
# Ruby 3.5 dropped `logger` from default gems; ActiveSupport
# (LoggerThreadSafeLevel) explodes on require unless it's pre-loaded.
# csim_rspec/csim_minitest pull capybara_simulated → transitively
# logger before spec_helper runs, but under CSIM_DRIVER=real those
# files return early and we're the first non-stdlib load — load logger
# defensively so Forem's `require "active_support"` succeeds.
require 'logger'
require 'bundler/setup'
require 'capybara'
require 'capybara/server'

module CsimRackTiming
  @total_ns = 0
  @count    = 0
  @lock     = Mutex.new

  class << self
    attr_reader :total_ns, :count

    def record(elapsed_ns)
      @lock.synchronize {
        @total_ns += elapsed_ns
        @count    += 1
      }
    end
  end

  class Middleware
    def initialize(app) = @app = app

    def call(env)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      @app.call(env)
    ensure
      CsimRackTiming.record(Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t0)
    end
  end

  module AppArgWrap
    def initialize(app, *rest, **kw)
      super(app.is_a?(Middleware) ? app : Middleware.new(app), *rest, **kw)
    end
  end

  module ConfigAppWrap
    def app=(rack_app)
      super(rack_app.is_a?(Middleware) ? rack_app : Middleware.new(rack_app))
    end
  end
end

Capybara::Config.prepend(CsimRackTiming::ConfigAppWrap)
Capybara::Server.prepend(CsimRackTiming::AppArgWrap)

# Only present when the host runs with CSIM_DRIVER=simulated (csim_rspec /
# csim_minitest require the gem; Cuprite runs don't load it).
Capybara::Simulated::Driver.prepend(CsimRackTiming::AppArgWrap) if defined?(Capybara::Simulated::Driver)


# `warn` is silenced under RSpec's Warning filter; `$stderr.puts` always
# reaches the terminal.
at_exit do
  next if CsimRackTiming.count.zero?
  total_ms = CsimRackTiming.total_ns / 1_000_000.0
  avg_ms   = total_ms / CsimRackTiming.count
  $stderr.puts "[rack-timing] #{CsimRackTiming.count} requests, total #{total_ms.round(1)} ms, avg #{avg_ms.round(2)} ms"
end
