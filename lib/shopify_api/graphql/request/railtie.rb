# frozen_string_literal: true

module ShopifyAPI
  module GraphQL
    class Railtie < Rails::Railtie
      rake_tasks do
        load File.expand_path("../../../tasks/shopify.rake", __dir__)

        # Task is also usable outside Rails, so only add the dep here
        Rake::Task["shopify:migrate_access_tokens"].enhance([:environment])
      end
    end
  end
end
