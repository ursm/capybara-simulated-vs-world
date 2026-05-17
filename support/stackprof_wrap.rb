# Sampling-profile the test process. Load via RUBYOPT.
# Output: $STACKPROF_OUT (default /tmp/forem.stackprof).
require 'stackprof'

out = ENV['STACKPROF_OUT'] || '/tmp/forem.stackprof'
mode = (ENV['STACKPROF_MODE'] || 'wall').to_sym
interval = (ENV['STACKPROF_INTERVAL'] || '1000').to_i

StackProf.start(mode: mode, interval: interval, raw: true)

at_exit do
  StackProf.stop
  StackProf.results(out)
  warn "[stackprof] wrote profile to #{out} (mode=#{mode}, interval=#{interval}us)"
end
