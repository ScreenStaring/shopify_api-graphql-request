# frozen_string_literal: true

require_relative "lib/shopify_api/graphql/request/version"

Gem::Specification.new do |spec|
  spec.name = "shopify_api-graphql-request"
  spec.version = ShopifyAPI::GraphQL::Request::VERSION
  spec.authors       = ["Skye Shaw"]
  spec.email         = ["skye.shaw@gmail.com"]

  spec.summary = "Small class to simplify the writing and handling of GraphQL queries and mutations for the Shopify Admin API. Comes with built-in retry, pagination, error handling, and more!"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.5.0" # Hash#slice
  spec.metadata = {
    "bug_tracker_uri"   => "https://github.com/ScreenStaring/shopify_api-graphql-request/issues",
    "changelog_uri"     => "https://github.com/ScreenStaring/shopify_api-graphql-request/blob/master/Changes",
    "documentation_uri" => "https://rubydoc.info/gems/shopify_api-graphql-request",
    "source_code_uri"   => "https://github.com/ScreenStaring/shopify_api-graphql-request",
  }

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "shopify_api-graphql-tiny", ">= 1.0.1", "< 2"
  spec.add_dependency "tiny_gid", , ">= 0.1.2", "< 2"
  spec.add_dependency "strings-case"

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "rake", ">= 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
