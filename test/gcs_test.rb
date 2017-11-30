require_relative "test_helper"
require "shrine/storage/linter"
require "date"
require "net/https"

describe Shrine::Storage::GoogleCloudStorage do
  def gcs(options = {})
    options[:bucket] ||= ENV.fetch("GCS_BUCKET")

    Shrine::Storage::GoogleCloudStorage.new(options)
  end

  def service_account
    {
      private_key: "-----BEGIN PRIVATE KEY-----
MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBANW9uQf69ivd+txc
v5iMYkTVkGcQIereNz/lYeuZv2s7OZ4I9pdebleUmpxPn/CopRxS3O7JrXBPzAMK
i0tFs/dnn5Ny6AIzZvo1eMSptoKmcHswoYTP9ftTG7cDa8/12woEFu+fX9ob4isF
IaKvbD8kEhcyynWPUH3pP1g0ssUPAgMBAAECgYAtQhgM5Yn8resxf/4d2hPwyVvj
Rto3tkfyoqqCTbLnjMndeb5lPNyWdOPsFzwhpEQZ5D3d3hx4fJ0RQ8lM7fx2EiwD
+gjiOzLu9Fy+9XiVPbqIR20R63sHlA2jmzTuno9TLRdi+YyBS3XUVjckSE9mqTNO
RDmDgRbwQURjsgFH2QJBAP9oNQrNQI2Q+b7ufA8pnf2ZWBX0ASFz99Y1WVR+ip7o
3pByI7EMK3g9h3Ua3yEU+g5WVb/1Zaj6Bx7p4lRL540CQQDWPMC2yXO9wnsw1Nyy
1gtD18hcPBwDbIoQIK+J/AOLtSryKrCAEvOnLsxU1krYAj6ZP5MwrruLmnTLUXCE
+ZoLAkEA2kJuGZX/VTsQAbcBc1+oMOCLIu+Ky9CzeW3LseYVhekQ0TWJBLKWr0E9
cbiN91JawkfLLaiCwJ0x2pwaGtlmvQJAK8PFapHEvyMXn2Ycn7vyGS3flFgDMP/f
RGQo9/svjj64QzhNThyRAbohq8MLDw2GVDAUlYFcdqxa553/amrC+QJBAOYsfZTF
0ICBD2rt+ukhgSmZq/4oWxlM505kDh4z+x2oT3nFSi+fce5IWuNswR2qTRhjIAj8
wXh0ExlzwgD2xJ0=
-----END PRIVATE KEY-----",
      client_email: 'test-shrine@test.google',
    }
  end

  before do
    @gcs = gcs
    shrine = Class.new(Shrine)
    shrine.storages = { gcs: @gcs }
    @uploader = shrine.new(:gcs)
  end

  after do
    @gcs.clear!
  end

  it "passes the linter" do
    Shrine::Storage::Linter.new(gcs).call(-> { image })
  end

  it "passes the linter with prefix" do
    Shrine::Storage::Linter.new(gcs(prefix: 'pre')).call(-> { image })
  end

  describe "default_acl" do
    it "does set default acl when uploading a new object" do
      gcs = gcs(default_acl: 'publicRead')
      gcs.upload(image, 'foo')

      url = URI(gcs.url('foo'))
      Net::HTTP.start(url.host, url.port, use_ssl: true) do |http|
        response = http.head(url.path)

        assert_equal "200", response.code
      end

      assert @gcs.exists?('foo')
    end

    it "does set default acl when copying an object" do
      gcs = gcs(default_acl: 'publicRead')
      object = @uploader.upload(image, location: 'foo')

      gcs.upload(object, 'bar')

      # foo needs to not be readable
      url_foo = URI(gcs.url('foo'))
      Net::HTTP.start(url_foo.host, url_foo.port, use_ssl: true) do |http|
        response = http.head(url_foo.path)
        assert_equal "403", response.code
      end

      # bar needs to be readable
      url_bar = URI(gcs.url('bar'))
      Net::HTTP.start(url_bar.host, url_bar.port, use_ssl: true) do |http|
        response = http.head(url_bar.path)
        assert_equal "200", response.code
      end

      assert @gcs.exists?('foo')
    end
  end

  describe "object_options" do
    it "does set the Cache-Control header when uploading a new object" do
      cache_control = 'public, max-age=7200'
      gcs = gcs(default_acl: 'publicRead', object_options: { cache_control: cache_control })
      gcs.upload(image, 'foo')

      assert @gcs.exists?('foo')

      url = URI(gcs.url('foo'))
      Net::HTTP.start(url.host, url.port, use_ssl: true) do |http|
        response = http.head(url.path)
        assert_equal "200", response.code
        assert_equal 1, response.get_fields('Cache-Control').size
        assert_equal cache_control, response.get_fields('Cache-Control')[0]
      end
    end

    it "does set the configured Cache-Control header when copying an object" do
      cache_control = 'public, max-age=7200'
      gcs = gcs(default_acl: 'publicRead', object_options: { cache_control: cache_control })
      object = @uploader.upload(image, location: 'foo')

      gcs.upload(object, 'bar')

      # bar needs to have the correct Cache-Control header
      url_bar = URI(gcs.url('bar'))
      Net::HTTP.start(url_bar.host, url_bar.port, use_ssl: true) do |http|
        response = http.head(url_bar.path)
        assert_equal "200", response.code
        assert_equal 1, response.get_fields('Cache-Control').size
        assert_equal cache_control, response.get_fields('Cache-Control')[0]
      end
    end
  end

  describe "#clear!" do
    it "does not empty the whole bucket when a prefix is set" do
      gcs_with_prefix = gcs(prefix: 'pre')
      @gcs.upload(image, 'foo')
      @gcs.upload(image, 'pre') # to ensure a file with the prefix name is not deleted
      gcs_with_prefix.clear!
      assert @gcs.exists?('foo')
      assert @gcs.exists?('pre')
    end
  end

  describe "#presign" do
    it "signs a GET url with a signing key and issuer" do
      gcs = gcs()
      gcs.upload(image, 'foo')

      sa = service_account
      Time.stub :now, Time.at(1486649900) do
        presign = gcs.presign(
          'foo',
          signing_key: sa[:private_key],
          issuer: sa[:client_email],
        )

        assert presign.url.start_with? "https://storage.googleapis.com/#{gcs.bucket}/foo?"
        assert presign.url.include? "Expires=1486650200"
        assert presign.url.include? "GoogleAccessId=test-shrine%40test.google"
        assert presign.url.include? "Signature=" # each tester's discovered signature will be different
        assert_equal({}, presign.fields)
      end
    end

    it "generated a signed url for a non-existing object" do
      gcs = gcs()

      Time.stub :now, Time.at(1486649900) do
        presign = gcs.presign('nonexisting')
        assert presign.url.include? "https://storage.googleapis.com/#{gcs.bucket}/nonexisting?"
        assert presign.url.include? "Expires=1486650200"
        assert presign.url.include? "Signature=" # each tester's discovered signature will be different
        assert_equal({}, presign.fields)
      end
    end

    it "signs a GET url with discovered credentials" do
      gcs = gcs()
      gcs.upload(image, 'foo')

      Time.stub :now, Time.at(1486649900) do
        presign = gcs.presign('foo')
        assert presign.url.include? "https://storage.googleapis.com/#{gcs.bucket}/foo?"
        assert presign.url.include? "Expires=1486650200"
        assert presign.url.include? "Signature=" # each tester's discovered signature will be different
        assert_equal({}, presign.fields)
      end
    end
  end

  describe "#url" do
    describe "signed" do
      it "url with `expires` signs a GET url with discovered credentials" do
        gcs = gcs()
        gcs.upload(image, 'foo')

        Time.stub :now, Time.at(1486649900) do
          presigned_url = gcs.url('foo', expires: 300)
          assert presigned_url.include? "https://storage.googleapis.com/#{gcs.bucket}/foo?"
          assert presigned_url.include? "Expires=1486650200"
          assert presigned_url.include? "Signature=" # each tester's discovered signature will be different
        end
      end

      it "url with `expires` signs a GET url with discovered credentials and specified host" do
        host = "123.mycdn.net"
        gcs = gcs(host: host)
        gcs.upload(image, 'foo')

        Time.stub :now, Time.at(1486649900) do
          presigned_url = gcs.url('foo', expires: 300)
          assert presigned_url.include? "https://#{host}/foo?"
          assert presigned_url.include? "Expires=1486650200"
          assert presigned_url.include? "Signature=" # each tester's discovered signature will be different
        end
      end
    end

    it "provides a storage.googleapis.com url by default" do
      gcs = gcs()
      url = gcs.url('foo')
      assert_equal("https://storage.googleapis.com/#{gcs.bucket}/foo", url)
    end

    it "accepts :host for specifying CDN links" do
      host = "123.mycdn.net"
      gcs = gcs(host: host)
      url = gcs.url('foo')
      assert_equal("https://123.mycdn.net/foo", url)
    end
  end

  describe '#upload' do
    it 'uploads a io stream to google cloud storage' do
      io = StringIO.new("data")

      file_key = random_key

      @gcs.upload(io, file_key)

      assert @gcs.exists?(file_key)
    end

    it 'uploads a non io object that responds to .to_io' do
      io = StringIO.new("data")
      file = FakeUploadedFile.new(io)

      file_key = random_key

      @gcs.upload(file, file_key)

      assert @gcs.exists?(file_key)
    end

    it 'uploads a non io object that responds to .tempfile' do
      io = StringIO.new("data")
      file = FakeOldUploadedFile.new(io)

      file_key = random_key

      @gcs.upload(file, file_key)

      assert @gcs.exists?(file_key)
    end
  end

  describe "#open" do
    it "returns an IO-like object around the file content" do
      gcs.upload(image, 'foo')
      io = gcs.open('foo')
      assert_equal(image.size, io.size)
      assert_equal(image.read, io.read)
      assert_instance_of(Google::Cloud::Storage::File, io.data[:file])
    end
  end
end
