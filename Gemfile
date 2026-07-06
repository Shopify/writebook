source "https://rubygems.org"

ruby file: ".ruby-version"

gem "rails", github: "Shopify/rails", branch: "writebook-ractorize"

# Ractor experiment: non-main Ractors dispatch DB queries to the main Ractor.
gem "ractor-dispatch"

# Drivers
gem "sqlite3", "~> 2.9"
gem "redis", ">= 4.0.1"

# Deployment
gem "puma", "~> 7.2", ">= 7.2.1"

# Jobs
gem "resque", "~> 2.6.0"
gem "resque-pool", "~> 0.7.1"

# Front-end
gem "propshaft"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"

# Other
gem "benchmark" # No longer a default gem as of Ruby 4.0; required by mini_magick
gem "jbuilder"
gem "redcarpet", "~> 3.6.1" # 3.6.1 ports to the TypedData C API (builds on Ruby 4.1+)
gem "rouge", "~> 4.5"
gem "bcrypt", "~> 3.1.7"
gem "image_processing", "~> 1.13"
gem "rqrcode"
gem "thruster"
gem "useragent", github: "basecamp/useragent"
gem "front_matter_parser"

group :development, :test do
  gem "debug"
  gem "faker", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
end
