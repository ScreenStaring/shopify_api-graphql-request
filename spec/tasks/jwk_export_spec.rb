# frozen_string_literal: true

require "rake"
require "stringio"
require "tmpdir"

RSpec.describe "shopify_api:graphql:request:jwk_export" do
  RSA_PEM = OpenSSL::PKey::RSA.generate(2048).to_pem
  EC_PEM = OpenSSL::PKey::EC.generate("prime256v1").to_pem

  before(:all) do
    Rake.application.rake_require("tasks/shopify", [File.expand_path("../../lib", __dir__)])
  end

  around do |example|
    original_env = ENV.to_h
    %w[KEY KID ALG].each { |key| ENV.delete(key) }

    example.run
  ensure
    ENV.replace(original_env)
  end

  def key_file(pem)
    path = File.join(@dir, "key.pem")
    File.write(path, pem)
    path
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  before do
    @task = Rake::Task["shopify_api:graphql:request:jwk_export"]
    @task.reenable
  end

  it "requires KEY" do
    ENV["KID"] = "key-1"
    ENV["ALG"] = "RS256"

    expect { @task.invoke }.to raise_error(SystemExit).and output(/KEY required/).to_stderr
  end

  it "rejects a KEY that is not a file" do
    ENV["KEY"] = File.join(@dir, "missing.pem")
    ENV["KID"] = "key-1"
    ENV["ALG"] = "RS256"

    expect { @task.invoke }.to raise_error(SystemExit).and output(/KEY file not found/).to_stderr
  end

  it "requires KID" do
    ENV["KEY"] = key_file(RSA_PEM)
    ENV["ALG"] = "RS256"

    expect { @task.invoke }.to raise_error(SystemExit).and output(/KID required/).to_stderr
  end

  it "requires ALG" do
    ENV["KEY"] = key_file(RSA_PEM)
    ENV["KID"] = "key-1"

    expect { @task.invoke }.to raise_error(SystemExit).and output(/ALG required/).to_stderr
  end

  it "rejects an unsupported ALG" do
    ENV["KEY"] = key_file(RSA_PEM)
    ENV["KID"] = "key-1"
    ENV["ALG"] = "HS256"

    expect { @task.invoke }.to raise_error(SystemExit).and output(/ALG must be one of: RS256, ES256/).to_stderr
  end

  it "rejects an invalid key" do
    ENV["KID"] = "key-1"
    ENV["ALG"] = "RS256"
    ENV["KEY"] = key_file("junk")

    expect { @task.invoke }.to raise_error(SystemExit).and output(/invalid key/).to_stderr
  end

  it "rejects a key that does not match ALG" do
    ENV["KID"] = "key-1"
    ENV["ALG"] = "RS256"
    ENV["KEY"] = key_file(EC_PEM)

    expect { @task.invoke }.to raise_error(SystemExit).and output(/key must be an RSA key for RS256/).to_stderr
  end

  it "exports an RSA public key" do
    ENV["KID"] = "key-1"
    ENV["ALG"] = "RS256"
    ENV["KEY"] = key_file(RSA_PEM)

    output = StringIO.new
    $stdout = output
    begin
      @task.invoke
    ensure
      $stdout = STDOUT
    end

    jwk = JSON.parse(output.string)
    expect(jwk).to include("kty" => "RSA", "kid" => "key-1", "alg" => "RS256", "use" => "sig", "e" => "AQAB")
    expect(jwk).to include("n")
    expect(jwk).to_not include("d")
  end

  it "exports an EC public key" do
    ENV["KID"] = "key-2"
    ENV["ALG"] = "ES256"
    ENV["KEY"] = key_file(EC_PEM)

    output = StringIO.new
    $stdout = output
    begin
      @task.invoke
    ensure
      $stdout = STDOUT
    end

    jwk = JSON.parse(output.string)
    expect(jwk).to include("kty" => "EC", "crv" => "P-256", "kid" => "key-2", "alg" => "ES256", "use" => "sig")
    expect(jwk).to include("x", "y")
    expect(jwk).to_not include("d")
  end
end
