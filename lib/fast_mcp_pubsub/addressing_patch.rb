# frozen_string_literal: true

require "cgi"

module FastMcpPubsub
  # Raised when a JSON-RPC response is sent with no client in scope. Delivering
  # it anyway would mean writing it to every connected SSE client.
  class UnaddressedResponseError < Error; end

  # The half of the RackTransport patch that makes a response reachable by the one
  # client that asked for it.
  #
  # FastMcp answers a JSON-RPC request over SSE and writes every message to every
  # connected stream, so before this the only thing keeping two clients apart was
  # JSON-RPC id matching — which fails the moment two of them open fresh sessions
  # in the same minute and both start counting ids from 1.
  #
  # Correlating a response with its client takes three pieces, and none of them
  # works alone: the client id has to reach the client (the endpoint URL), come
  # back on its POSTs (the capture), and have somewhere to be delivered to (the
  # targeted send).
  module AddressingPatch
    # The members that make a JSON-RPC message a response rather than a
    # notification or a request.
    RESPONSE_KEYS = %w[result error].freeze

    def self.apply!
      add_targeted_send
      add_sse_writer
      add_client_id_capture
      add_endpoint_client_id
    end

    # Delivery to one named SSE client, the counterpart of FastMcp's own
    # send_message. Returns false when this worker does not hold the client,
    # which is the normal answer on every worker but one.
    def self.add_targeted_send
      FastMcp::Transports::RackTransport.class_eval do
        return if method_defined?(:send_local_message_to)

        define_method(:send_local_message_to) do |client_id, message|
          client = @sse_clients[client_id]
          return false unless client

          write_sse_payload(client, message.is_a?(String) ? message : JSON.generate(message))
        rescue StandardError => e
          FastMcpPubsub.logger.info "RackTransport: Client #{client_id} unreachable (#{e.message}), unregistering"
          unregister_sse_client(client_id)
          false
        end
      end
    end

    def self.add_sse_writer
      FastMcp::Transports::RackTransport.class_eval do
        return if method_defined?(:write_sse_payload)

        define_method(:write_sse_payload) do |client, json_message|
          stream = client[:stream]
          mutex = client[:mutex]
          return false if stream.nil? || mutex.nil? || (stream.respond_to?(:closed?) && stream.closed?)

          mutex.synchronize do
            stream.write("data: #{json_message}\n\n")
            stream.flush if stream.respond_to?(:flush)
          end
          true
        end
        private :write_sse_payload
      end
    end

    # Records which client the POST belongs to, so send_message can address the
    # response FastMcp is about to write.
    #
    # A POST without a client_id is refused before it runs. Every endpoint the
    # server hands out carries one, so such a POST comes from a client that
    # ignored its endpoint, and the only place its response could go is every
    # open stream: one client's data in everybody's session.
    #
    # request.GET rather than request.params on purpose: params merges the POST
    # body, and reading the body here would leave nothing for the JSON parse that
    # follows.
    def self.add_client_id_capture
      FastMcp::Transports::RackTransport.class_eval do
        return unless private_method_defined?(:handle_message_request_with_server)
        return if private_method_defined?(:handle_message_request_without_pubsub)

        alias_method :handle_message_request_without_pubsub, :handle_message_request_with_server

        define_method(:handle_message_request_with_server) do |request, server|
          client_id = request.GET["client_id"]
          return missing_client_id_response(request) if client_id.to_s.empty?

          FastMcpPubsub::CurrentClient.with(client_id) { handle_message_request_without_pubsub(request, server) }
        end

        define_method(:missing_client_id_response) do |request|
          FastMcpPubsub.logger.warn "FastMcpPubsub: Refused #{request.request_method} #{request.path} without client_id from #{request.ip} (#{request.user_agent})"
          json_rpc_error_response(400, -32_600, "Invalid Request: client_id is missing; POST to the endpoint URL the SSE stream sent")
        end
        private :handle_message_request_with_server, :missing_client_id_response
      end
    end

    # Puts the client id into the endpoint URL FastMcp hands the client on
    # connect, so the client's POSTs come back carrying it.
    #
    # FastMcp echoes the SSE request's own query string into that endpoint and
    # never adds the id it just generated, so without this the capture above has
    # nothing to read and every response falls back to the fan-out.
    def self.add_endpoint_client_id
      FastMcp::Transports::RackTransport.class_eval do
        return unless private_method_defined?(:setup_sse_connection)
        return if private_method_defined?(:setup_sse_connection_without_pubsub)

        alias_method :setup_sse_connection_without_pubsub, :setup_sse_connection

        define_method(:setup_sse_connection) do |client_id, io, env|
          FastMcpPubsub::AddressingPatch.apply_write_timeout(io)
          query = FastMcpPubsub::AddressingPatch.query_with_client_id(env["QUERY_STRING"], client_id)
          setup_sse_connection_without_pubsub(client_id, io, env.merge("QUERY_STRING" => query))
        end
        private :setup_sse_connection
      end
    end

    # Bounds how long a write to one SSE client may block. A client that vanished
    # without closing its TCP connection otherwise blocks the writer until TCP
    # gives up (56 s in production), and that writer is the worker's PubSub
    # listener thread, so every SSE response on the worker waits behind it.
    #
    # A blocked write then raises IO::TimeoutError, an IOError, which
    # send_local_message_to and FastMcp's keep-alive loop already treat as a
    # disconnect. IO#timeout= exists since Ruby 3.2; an IO without it is logged
    # rather than quietly left unbounded.
    def self.apply_write_timeout(io)
      if io.respond_to?(:timeout=)
        io.timeout = FastMcpPubsub.config.sse_write_timeout
      else
        FastMcpPubsub.logger.warn "FastMcpPubsub: #{io.class} takes no write timeout; a vanished SSE client can block its writer"
      end
    end

    # A JSON-RPC response belongs to the client whose request produced it. With no
    # client in scope the only delivery left is every open stream, so the
    # response is refused loudly instead. Notifications and server-to-client
    # requests carry a method rather than a result, and still fan out.
    def self.ensure_addressed!(message, client_id)
      return if client_id

      fields = message.is_a?(String) ? JSON.parse(message) : message
      return unless fields.is_a?(Hash) && fields.keys.map(&:to_s).intersect?(RESPONSE_KEYS)

      raise UnaddressedResponseError, "JSON-RPC response id=#{(fields[:id] || fields["id"]).inspect} has no client in scope; it would reach every SSE client"
    end

    # Appends client_id to an SSE query string, leaving a client that named its
    # own id alone — FastMcp honours that one, so overriding it would hand back an
    # endpoint pointing at a different session than the stream it arrived on.
    def self.query_with_client_id(query_string, client_id)
      return query_string if query_string.to_s.match?(/(\A|&)client_id=/)

      [query_string, "client_id=#{CGI.escape(client_id.to_s)}"].reject { |part| part.to_s.empty? }.join("&")
    end
  end
end
