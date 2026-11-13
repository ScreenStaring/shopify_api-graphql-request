# frozen_string_literal: true
require "base64"

RSpec.describe ShopifyAPI::GraphQL::Request::OAuth::ClientAssertion do
  RSA_KEY = OpenSSL::PKey::RSA.generate(2048)
  EC_KEY = OpenSSL::PKey::EC.generate("prime256v1")

  def public_key(key)
    # PKey#public_to_pem requires the openssl gem 3.0+ (Ruby 3.0+)
    return OpenSSL::PKey.read(key.public_to_pem) if key.respond_to?(:public_to_pem)

    if key.is_a?(OpenSSL::PKey::EC)
      pub = OpenSSL::PKey::EC.new(key.group)
      pub.public_key = key.public_key
      pub
    else
      key.public_key
    end
  end

  def decode(segment)
    Base64.urlsafe_decode64(segment)
  end

  def assertion(key = RSA_KEY, client_id = "client-id", key_id = "key-id")
    described_class.new(client_id, key, key_id)
  end

  describe ".new" do
    it "requires a client ID" do
      expect { assertion(RSA_KEY, " ") }.to raise_error(ArgumentError, "client_id required")
    end

    it "requires a key ID" do
      expect { assertion(RSA_KEY, "id", nil) }.to raise_error(ArgumentError, "key_id required")
    end

    it "rejects a key ID with surrounding whitespace" do
      expect { assertion(RSA_KEY, "id", " key") }.to raise_error(ArgumentError, /whitespace/)
    end

    it "rejects a client ID over 255 characters" do
      expect { assertion(RSA_KEY, "a" * 256) }.to raise_error(ArgumentError, "client_id too long")
    end

    it "accepts a PEM String" do
      expect { assertion(RSA_KEY.to_pem) }.to_not raise_error
      expect { assertion(EC_KEY.to_pem) }.to_not raise_error
    end

    it "rejects an invalid PEM String" do
      expect { assertion("nope") }.to raise_error(ArgumentError, /invalid private_key/)
    end

    it "rejects a public key" do
      expect { assertion(public_key(RSA_KEY)) }.to raise_error(ArgumentError, /private key/)
      expect { assertion(public_key(EC_KEY)) }.to raise_error(ArgumentError, /private key/)
    end

    it "rejects an RSA key under 2048 bits" do
      expect { assertion(OpenSSL::PKey::RSA.generate(1024)) }.to raise_error(ArgumentError, /2048/)
    end

    it "rejects an unsupported EC curve" do
      expect { assertion(OpenSSL::PKey::EC.generate("secp384r1")) }.to raise_error(ArgumentError, /prime256v1/)
    end

    it "rejects a nil key" do
      expect { assertion(nil) }.to raise_error(ArgumentError, "private_key required")
    end
  end

  describe "#to_jwt" do
    it "requires a shop" do
      expect { assertion.to_jwt(" ") }.to raise_error(ArgumentError, "shop required")
    end

    [["RS256", RSA_KEY], ["ES256", EC_KEY]].each do |alg, key|
      context "with #{alg}" do
        before do
          @parts = assertion(key).to_jwt("my-shop").split(".")
        end

        it "has a valid header" do
          expect(JSON.parse(decode(@parts[0]))).to eq("alg" => alg, "kid" => "key-id")
        end

        it "has valid claims" do
          claims = JSON.parse(decode(@parts[1]))

          expect(claims["iss"]).to eq("client-id")
          expect(claims["sub"]).to eq("client-id")
          expect(claims["aud"]).to eq("https://my-shop.myshopify.com/admin/oauth/access_token")
          expect(claims["exp"]).to eq(claims["iat"] + 60)
          expect(claims["jti"]).to_not be_empty
        end

        it "uses a unique jti each time" do
          other = assertion(key).to_jwt("my-shop").split(".")
          expect(JSON.parse(decode(@parts[1]))["jti"]).to_not eq(JSON.parse(decode(other[1]))["jti"])
        end

        it "has a signature verifiable with the public key" do
          signature = decode(@parts[2])
          expect(signature.bytesize).to eq(64) if alg == "ES256"

          signature = OpenSSL::ASN1::Sequence([
            OpenSSL::ASN1::Integer(OpenSSL::BN.new(signature[0, 32], 2)),
            OpenSSL::ASN1::Integer(OpenSSL::BN.new(signature[32, 32], 2))
          ]).to_der if alg == "ES256"

          expect(public_key(key).verify(OpenSSL::Digest.new("SHA256"), signature, @parts[0..1].join("."))).to be(true)
        end
      end
    end

    it "does not double the domain suffix" do
      claims = JSON.parse(decode(assertion.to_jwt("my-shop.myshopify.com").split(".")[1]))
      expect(claims["aud"]).to eq("https://my-shop.myshopify.com/admin/oauth/access_token")
    end
  end
end
