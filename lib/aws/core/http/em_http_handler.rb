# http://docs.amazonwebservices.com/AWSRubySDK/latest/
require 'hot_tub'
require 'em-synchrony'
require 'em-synchrony/em-http'
require 'em-synchrony/thread'
module AWS
  module Core
    module Http

      # An EM-Synchrony implementation for Fiber based asynchronous ruby application.
      # See https://github.com/igrigorik/async-rails and
      # http://www.mikeperham.com/2010/04/03/introducing-phat-an-asynchronous-rails-app/
      # for examples of Aync-Rails application
      #
      # In Rails add the following to you various environment files:
      #
      # require 'aws-sdk'
      # require 'aws/core/http/em_http_handler'
      # AWS.config(
      #   :http_handler => AWS::Http::EMHttpHandler.new(
      #   :proxy => {:host => "http://myproxy.com",
      #   :port => 80,
      #   :pool_size => 20, # not set by default which disables connection pooling
      #   :async => false # if set to true all requests are handle asynchronously and initially return nil
      #   }))
      class EMHttpHandler

        EM_PASS_THROUGH_ERRORS = [
          NoMethodError, FloatDomainError, TypeError, NotImplementedError,
          SystemExit, Interrupt, SyntaxError, RangeError, NoMemoryError,
          ArgumentError, ZeroDivisionError, LoadError, NameError,
          LocalJumpError, SignalException, ScriptError,
          SystemStackError, RegexpError, IndexError,
        ]
        # @return [Hash] The default options to send to EM-Synchrony on each request.
        attr_reader :default_request_options

        # Constructs a new HTTP handler using EM-Synchrony.
        # @param [Hash] options Default options to send to EM-Synchrony on
        # each request. These options will be sent to +get+, +post+,
        # +head+, +put+, or +delete+ when a request is made. Note
        # that +:body+, +:head+, +:parser+, and +:ssl_ca_file+ are
        # ignored. If you need to set the CA file, you should use the
        # +:ssl_ca_file+ option to {AWS.config} or
        # {AWS::Configuration} instead.
        def initialize options = {}
          @default_request_options = options
          @client_options = {
            :inactivity_timeout => (options[:inactivity_timeout] || 0),
            :connect_timeout => (options[:connect_timeout] || 10)
          }
          @pool_options = {
            :size => ((options[:pool_size].to_i || 5)),
            :never_block => (options[:never_block].nil? ? true : options[:never_block]),
            :blocking_timeout => (options[:pool_timeout] || 10)
          }
          if @pool_options[:size] > 0
            @pool = HotTub::Session.new { |url| HotTub::Pool.new(@pool_options) {EM::HttpRequest.new(url,@client_options)}}
          end
        end

        def handle(request,response,&read_block)
          if EM::reactor_running?
            process_request(request,response,&read_block)
          else
            EM.synchrony do
              process_request(request,response,&read_block)
              @pool.close_all if @pool
              EM.stop
            end
          end
        end

        # If the request option :async are set to true that request will  handled
        # asynchronously returning nil initially and processing in the background
        # managed by EM-Synchrony. If the client option :async all requests will
        # be handled asynchronously.
        # EX:
        #     EM.synchrony do
        #       s3 = AWS::S3.new
        #       s3.obj.write('test', :async => true) => nil
        #       EM::Synchrony.sleep(2)
        #       s3.obj.read => # 'test'
        #       EM.stop
        #     end
        def handle_async(request,response,handle,&read_block)
          if EM::reactor_running?
            process_request(request,response,true,&read_block)
          else
            EM.synchrony do
              process_request(request,response,true,&read_block)
              @pool.close_all if @pool
              EM.stop
            end
          end
        end

        private

        def fetch_url(request)
          "#{(request.use_ssl? ? "https" : "http")}://#{request.host}:#{request.port}"
        end

        def fetch_headers(request)
          headers = { 'content-type' => '' }
          request.headers.each_pair do |key,value|
            headers[key] = value.to_s
          end
          {:head => headers}
        end

        def fetch_proxy(request)
          opts={}
          if request.proxy_uri
            opts[:proxy] = {:host => request.proxy_uri.host,:port => request.proxy_uri.port}
          end
          opts
        end

        def fetch_ssl(request)
          opts = {}
          if request.use_ssl? && request.ssl_verify_peer?
            opts[:private_key_file] = request.ssl_ca_file
            opts[:cert_chain_file]= request.ssl_ca_file
          end
          opts
        end

        def fetch_request_options(request)
          opts = default_request_options.
            merge(fetch_headers(request).
                  merge(fetch_proxy(request)).
                  merge(fetch_ssl(request)))
            opts[:query] = request.querystring
          if request.body_stream.respond_to?(:path)
            opts[:file] = request.body_stream.path
          else
            opts[:body] = request.body.to_s
          end
          opts[:path] = request.path if request.path
          opts
        end

        def fetch_response(request,opts={},&read_block)
          method = "a#{request.http_method}".downcase.to_sym  # aget, apost, aput, adelete, ahead
          url = fetch_url(request)
          if @pool
            @pool.run(url) do |connection|
              req = connection.send(method, {:keepalive => true}.merge(opts))
              req.stream &read_block if block_given?
              return  EM::Synchrony.sync req unless opts[:async]
            end
          else
            opts = @client_options.merge(:inactivity_timeout => request.read_timeout)
            req = EM::HttpRequest.new(url,opts).send(method,opts)
            req.stream &read_block if block_given?
            return  EM::Synchrony.sync req unless opts[:async]
          end
          nil
        end

        # AWS needs all header keys downcased and values need to be arrays
        def fetch_response_headers(response)
          response_headers = response.response_header.raw.to_hash
          aws_headers = {}
          response_headers.each_pair do  |k,v|
            key = k.downcase
            #['x-amz-crc32', 'x-amz-expiration','x-amz-restore','x-amzn-errortype']
            if v.is_a?(Array)
              aws_headers[key] = v
            else
              aws_headers[key] = [v]
            end
          end
          response_headers.merge(aws_headers)
        end

        # Builds and attempts the request. Occasionally under load em-http-request
        # em-http-request returns a status of 0 for various http timeouts, see:
        # https://github.com/igrigorik/em-http-request/issues/76
        # https://github.com/eventmachine/eventmachine/issues/175
        def process_request(request,response,async=false,&read_block)
          opts = fetch_request_options(request)
          opts[:async] = (async || opts[:async])
          begin
            http_response = fetch_response(request,opts,&read_block)
            unless opts[:async]
              response.status = http_response.response_header.status.to_i
              raise Timeout::Error if response.status == 0
              response.headers = fetch_response_headers(http_response)
              response.body = http_response.response
            end
          rescue Timeout::Error => error
            response.network_error = error
          rescue *EM_PASS_THROUGH_ERRORS => error
            raise error
          rescue Exception => error
            response.network_error = error
          end
          nil
        end
      end
    end
  end

  # We move this from AWS::Http to AWS::Core::Http, but we want the
  # previous default handler to remain accessible from its old namespace
  # @private
  module Http
    class EMHttpHandler < Core::Http::EMHttpHandler; end
  end
end
