# frozen_string_literal: true

require "fileutils"

# A hard link to +source+ at +link+, for a spec that needs a file with a second
# name. A tmp dir may be on another device than the source (/tmp and /var/tmp on
# some CI runners): then the link's other name is a copy beside it, which is all
# Guardrails::Outside can see of a hard link anyway (its link count).
module HardLink
  def hard_link(source, link)
    File.link(source, link)
  rescue Errno::EXDEV
    beside = "#{link}.source"
    FileUtils.cp(source, beside)
    File.link(beside, link)
  end
end

RSpec.configure { |config| config.include HardLink }
