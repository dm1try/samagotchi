# frozen_string_literal: true

require "open3"
require "tmpdir"
require "spec_helper"
require "samagotchi/desktop"

RSpec.describe "the desktop helper's Swift sources", :macos_build do
  it "compile into a signed app with the Service in its Info.plist" do
    Dir.mktmpdir("desktop-build") do |tmp|
      macos = Samagotchi::Desktop::MacOS.new(app_dir: File.join(tmp, "Apps"), support_dir: File.join(tmp, "Support"),
                                             register: false)
      macos.install
      app = macos.app_path
      _out, status = Open3.capture2e("codesign", "--verify", app)
      expect(status).to be_success
      expect(File.executable?(File.join(app, "Contents", "MacOS", "ChiHelper"))).to be(true)
      plist, = Open3.capture2("plutil", "-convert", "json", "-o", "-", File.join(app, "Contents", "Info.plist"))
      expect(plist).to include('"NSMessage":"sendToChi"', '"LSUIElement":true', '"NSSendFileTypes":["public.image"]')
    end
  end
end
