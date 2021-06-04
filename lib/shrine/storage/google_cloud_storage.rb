require "shrine"
require "google/cloud/storage"
require "down/chunked_io"

class Shrine
  module Storage
    class GoogleCloudStorage
      attr_reader :bucket, :prefix, :host

      # Initialize a Shrine::Storage for GCS allowing for auto-discovery of the Google::Cloud::Storage client.
      # @param [String] project Provide if not using auto discovery
      # @see http://googlecloudplatform.github.io/google-cloud-ruby/#/docs/google-cloud-storage/v1.6.0/guides/authentication#environmentvariables for information on discovery
      def initialize(project: nil, bucket:, prefix: nil, host: nil, default_acl: nil, object_options: {}, credentials: nil)
        @project = project
        @bucket = bucket
        @prefix = prefix
        @host = host
        @default_acl = default_acl
        @object_options = object_options
        @storage = nil
        @credentials = credentials
      end

      # If the file is an UploadFile from GCS, issues a copy command, otherwise it uploads a file.
      # @param [IO] io - io like object
      # @param [String] id - location
      def upload(io, id, shrine_metadata: {}, **options)
        if copyable?(io)
          existing_file = get_bucket(io.storage.bucket).file(io.storage.object_name(io.id))
          file = existing_file.copy(
              @bucket, # dest_bucket_or_path - the bucket to copy the file to
              object_name(id), # dest_path - the path to copy the file to in the given bucket
              acl: options.fetch(:acl) { @default_acl }
          ) do |f|
            # Workaround a bug in File#copy where the content-type is not copied if you provide a block
            # See https://github.com/renchap/shrine-google_cloud_storage/issues/36
            # See https://github.com/googleapis/google-cloud-ruby/issues/4254
            f.content_type = existing_file.content_type

            # update the additional options
            @object_options.merge(options).each_pair do |key, value|
              f.send("#{key}=", value)
            end
          end
          file
        else
          with_file(io) do |file|
            file_options = @object_options.merge(
              content_type: shrine_metadata["mime_type"],
              acl: options.fetch(:acl) { @default_acl }
            ).merge(options)

            get_bucket.create_file(
                file,
                object_name(id), # path
                **file_options
            )
          end
        end
      end

      # URL to the remote file, accepts options for customizing the URL
      def url(id, **options)
        if @default_acl == 'publicRead'
          host = @host || "storage.googleapis.com/#{@bucket}"
          "https://#{host}/#{object_name(id)}"
        else
          signed_url = storage.signed_url(@bucket, object_name(id), **options)
          signed_url.gsub!(/storage.googleapis.com\/#{@bucket}/, @host) if @host
          signed_url
        end
      end

      # Opens the remote file and returns it as `Down::ChunkedIO` object.
      # @return [Down::ChunkedIO] object
      # @see https://github.com/janko-m/down#downchunkedio
      def open(id, rewindable: true, **options)
        file = get_file(id)

        raise Shrine::FileNotFound, "file #{id.inspect} not found on storage" unless file

        # create enumerator which lazily yields chunks of downloaded content
        chunks = Enumerator.new do |yielder|
          # trick to get google client to stream the download
          proc_io = ProcIO.new { |data| yielder << data }
          file.download(proc_io, verify: :none, **options)
        end

        # wrap chunks in an IO-like object which downloads when needed
        Down::ChunkedIO.new(
          chunks:     chunks,
          size:       file.size,
          rewindable: rewindable,
          data:       { file: file },
        )
      end

      # checks if the file exists on the storage
      def exists?(id)
        file = get_file(id)
        return false if file.nil?
        file.exists?
      end

      # deletes the file from the storage
      def delete(id)
        file = get_file(id)
        delete_file(file) unless file.nil?
      end

      # deletes all objects from the storage
      # If block is givem, deletes only objects for which
      # the block evaluates to true.
      #
      # clear!
      # # or
      # clear! { |file| file.updated_at < 1.week.ago }
      def clear!(&block)
        prefix = "#{@prefix}/" if @prefix
        files = get_bucket.files prefix: prefix

        loop do
          files.each { |file| delete_file(file) if block.nil? || block.call(file) }
          files = files.next or break
        end
      end

      # returns request data (:method, :url, and :headers) for direct uploads
      def presign(id, **options)
        url = storage.signed_url(@bucket, object_name(id), method: "PUT", **options)

        headers = {}
        headers["Content-Type"] = options[:content_type] if options[:content_type]
        headers["Content-MD5"]  = options[:content_md5] if options[:content_md5]
        headers.merge!(options[:headers]) if options[:headers]

        { method: :put, url: url, headers: headers }
      end

      def object_name(id)
        @prefix ? "#{@prefix}/#{id}" : id
      end

      private

      def get_file(id)
        get_bucket.file(object_name(id))
      end

      def get_bucket(bucket_name = @bucket)
        storage.bucket(bucket_name, skip_lookup: true)
      end

      # @see http://googlecloudplatform.github.io/google-cloud-ruby/#/docs/google-cloud-storage/v1.6.0/guides/authentication
      def storage
        return @storage if @storage

        opts = {}
        opts[:project] = @project if @project
        opts[:credentials] = @credentials if @credentials

        @storage = Google::Cloud::Storage.new(**opts)
      end

      def copyable?(io)
        io.is_a?(UploadedFile) &&
          io.storage.is_a?(Storage::GoogleCloudStorage)
        # TODO: add a check for the credentials
      end

      def with_file(io)
        if io.respond_to?(:tempfile) # ActionDispatch::Http::UploadedFile
          yield io.tempfile
        else
          Shrine.with_file(io) { |file| yield file }
        end
      end

      # deletes file with ignoring NotFoundError
      def delete_file(file)
        begin
          file.delete
        rescue Google::Cloud::NotFoundError
          # we're fine if the file was already deleted
        end
      end

      # This class provides a writable IO wrapper around a proc object, with
      # #write simply calling the proc, which we can pass in as the destination
      # IO for download.
      class ProcIO
        def initialize(&proc)
          @proc = proc
        end

        def write(data)
          @proc.call(data)
          data.bytesize # match return value of other IO objects
        end

        # TODO: Remove this once google/google-api-ruby-client#638 is merged.
        def flush
          # google-api-client calls this method
        end
      end
    end
  end
end
