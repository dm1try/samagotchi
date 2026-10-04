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
  gem "rspec", "~> 3"
  gem "webmock"
  gem "parallel_tests"
end

group :lint do
  gem "rubocop", "~> 1.91", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rspec", require: false
end
