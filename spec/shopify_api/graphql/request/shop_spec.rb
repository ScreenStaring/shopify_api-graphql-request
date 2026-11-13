# frozen_string_literal: true

RSpec.describe ShopifyAPI::GraphQL::Request::Shop do
  describe ".new" do
    it "requires a shop" do
      expect { described_class.new(nil) }.to raise_error(ArgumentError, "shop required")
    end

    it "requires a non-blank shop" do
      expect { described_class.new("  ") }.to raise_error(ArgumentError, "shop required")
    end

    it "requires a shop that is not just a scheme" do
      expect { described_class.new("https://") }.to raise_error(ArgumentError, "shop required")
    end
  end

  describe "#to_s" do
    it "qualifies a handle" do
      expect(described_class.new("my-shop").to_s).to eq("my-shop.myshopify.com")
    end

    it "does not re-qualify a domain" do
      expect(described_class.new("my-shop.myshopify.com").to_s).to eq("my-shop.myshopify.com")
    end

    it "removes the scheme" do
      expect(described_class.new("https://my-shop.myshopify.com").to_s).to eq("my-shop.myshopify.com")
      expect(described_class.new("http://my-shop").to_s).to eq("my-shop.myshopify.com")
    end

    it "strips surrounding whitespace" do
      expect(described_class.new(" my-shop ").to_s).to eq("my-shop.myshopify.com")
    end

    it "does not modify the given String" do
      shop = "my-shop".freeze
      described_class.new(shop)

      expect(shop).to eq("my-shop")
    end

    it "accepts a Shop" do
      expect(described_class.new(described_class.new("my-shop")).to_s).to eq("my-shop.myshopify.com")
    end
  end

  describe "#to_str" do
    it "returns the qualified domain" do
      expect(described_class.new("my-shop").to_str).to eq("my-shop.myshopify.com")
    end

    it "allows implicit conversion to a String" do
      expect("https://" + described_class.new("my-shop")).to eq("https://my-shop.myshopify.com")
    end
  end
end
