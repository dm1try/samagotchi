# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies (reline, nokogiri, rack, rackup, webrick) come from
# samagotchi.gemspec.
gemspec

# Optional at runtime: Markdown rendering in `chi web` (--web-markdown).
group :markdown do
  gem "commonmarker"
end

group :development do
  gem "rake", "~> 13"
end

group :test do
  # `chi bundle test` runs a bundle's Minitest tests: the specs run it from
  # this bundle (CI's gems are vendored; Ruby's own minitest isn't on it).
  gem "minitest", require: false
  gem "parallel_tests"
  gem "rspec", "~> 3"
  gem "webmock"
end

group :lint do
  gem "rubocop", "~> 1.91", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rspec", require: false
end
