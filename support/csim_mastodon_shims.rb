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

# Match Playwright's default viewport (1280×720). Mastodon's UI gates
# the compose-side-panel render on `useBreakpoint('full')` ≡ viewport
# ≤ 1174, so the simulated driver's 1024×768 default falls below the
# threshold and `form.compose-form` never renders — breaking specs
# that fill it in (`new_statuses_spec`, `report_interface_spec`,
# `share_entrypoint_spec`).
module CsimMastodonViewport
  # Mastodon's UI gates the compose-side-panel render on
  # `useBreakpoint('full')` ≡ viewport ≤ 1174. Match Playwright's
  # 1280×720 default so `form.compose-form` actually renders for
  # specs that fill it in (`new_statuses_spec`, `report_interface_spec`,
  # `share_entrypoint_spec`). RSpec `before(:each, :js)` runs *after*
  # the simulated-driver Driver#initialize, but Mastodon's own
  # `before(:each, :js)` (which flips `driven_by`) registers later
  # in the load order, so it wins over our before-hook. Hooking
  # initialize directly sidesteps the ordering question.
  def initialize(*a, **kw)
    super
    browser.set_viewport(1280, 720)
  end
end

Capybara::Simulated::Driver.prepend(CsimMastodonViewport)
