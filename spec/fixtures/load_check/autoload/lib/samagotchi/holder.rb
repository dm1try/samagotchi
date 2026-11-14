module Samagotchi
  autoload :Widget, File.expand_path("widget", __dir__)
  autoload :Single, File.expand_path("single", __dir__)

  class Holder
    def widget = Widget.new
    def single = Single.new
  end
end
