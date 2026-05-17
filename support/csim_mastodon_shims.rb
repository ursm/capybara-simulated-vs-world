# Mastodon-specific compatibility shims for `bin/run-mastodon`.
# Loaded via RUBYOPT after csim_rspec, only when CSIM_DRIVER=simulated.
#
# Mastodon's test suite (spec/support/browser_errors.rb) was written
# assuming `:playwright` is the JS driver and calls
# `Capybara.current_session.driver.with_playwright_page { |page| page.on(...) }`
# to attach a browser-console listener inside a `before(:each, :js)`
# hook. Our `:simulated` driver doesn't have that method — without a
# stub, every :js spec errors before reaching the test body. Provide a
# no-op so the hook's `example.metadata[:js_console_messages] ||= []`
# initialisation still runs and the after-hook sees an empty list.

return unless ENV['CSIM_DRIVER'] == 'simulated'

require 'capybara/simulated'

module CsimPlaywrightCompat
  class NullPage
    def on(*_, &_); end
  end

  module WithPlaywrightPage
    def with_playwright_page
      yield NullPage.new if block_given?
    end
  end
end

Capybara::Simulated::Driver.prepend(CsimPlaywrightCompat::WithPlaywrightPage)
