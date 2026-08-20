# frozen_string_literal: true

module FastMcpPubsub
  # Core PostgreSQL NOTIFY/LISTEN service for broadcasting MCP messages across Puma workers
  class Service
    MAX_PAYLOAD_SIZE = 7800 # PostgreSQL NOTIFY limit is 8000 bytes, leave some margin

    class << self
      attr_reader :listener_thread, :dedicated_connection
      attr_accessor :shutdown_requested

      # Publishes one MCP message to the cluster.
      #
      # client_id names the SSE client the message answers; nil means it is for
      # everyone, which is what a genuine notification is. A response carries an
      # id because every worker receives every NOTIFY, and without one the worker
      # holding an unrelated session would write this answer into it.
      def broadcast(message, client_id = nil)
        envelope = envelope_for(message)
        envelope[:_pubsub_target] = client_id if client_id

        send_payload(envelope.to_json)
      rescue StandardError => e
        FastMcpPubsub.logger.error "FastMcpPubsub: Error broadcasting message: #{e.message}"
        raise
      end

      def start_listener
        unless FastMcpPubsub.config.enabled
          FastMcpPubsub.logger.info "FastMcpPubsub: Not starting listener - disabled in config for PID #{Process.pid}"
          return
        end

        if @listener_thread&.alive?
          FastMcpPubsub.logger.info "FastMcpPubsub: Listener already running for PID #{Process.pid}"
          return
        end

        FastMcpPubsub.logger.info "FastMcpPubsub: Starting listener thread for PID #{Process.pid}"

        @listener_thread = Thread.new do
          Thread.current.name = "fast-mcp-pubsub-listener"
          listen_loop
        end

        # Register shutdown hook
        at_exit { stop_listener }
      end

      def stop_listener
        # A thread that has already died on its own still leaves its reference
        # behind, and every caller reads that reference as "a listener is
        # running". Clearing it is part of stopping, not a separate errand.
        return @listener_thread = nil unless @listener_thread&.alive?

        FastMcpPubsub.logger.info "FastMcpPubsub: Stopping listener thread for PID #{Process.pid}"
        @shutdown_requested = true

        # Cancel wait_for_notify to wake up the thread
        begin
          @dedicated_connection&.cancel
        rescue StandardError
          nil
        end

        @listener_thread.join(5) # Wait max 5 seconds

        # Force kill if still alive after timeout (e.g. stuck in PG.connect during reconnect)
        if @listener_thread&.alive?
          @listener_thread.kill
          @listener_thread.join(1)
        end

        @listener_thread = nil

        # Close dedicated connection
        begin
          @dedicated_connection&.close
        rescue StandardError
          nil
        end
        @dedicated_connection = nil
        @shutdown_requested = false
      end

      private

      def send_payload(payload)
        channel = FastMcpPubsub.config.channel_name
        FastMcpPubsub.logger.debug "FastMcpPubsub: Broadcasting message to #{channel}: #{payload.bytesize} bytes"

        ActiveRecord::Base.connection.execute(
          "NOTIFY #{channel}, #{ActiveRecord::Base.connection.quote(payload)}"
        )
      end

      def payload_too_large?(payload)
        payload.bytesize > MAX_PAYLOAD_SIZE
      end

      # Wraps the message for the wire: inline when it fits in a NOTIFY, a
      # database reference when it does not. The envelope is also what gives the
      # target somewhere to live.
      def envelope_for(message)
        payload = message.to_json
        return { _pubsub_message: message } unless payload_too_large?(payload)

        ref_id = MessageStore.store(payload)
        FastMcpPubsub.logger.debug "FastMcpPubsub: Payload too large (#{payload.bytesize} bytes), stored as #{ref_id}"
        { _pubsub_ref: ref_id }
      end

      def listen_loop
        channel = FastMcpPubsub.config.channel_name

        begin
          @dedicated_connection = create_dedicated_connection

          FastMcpPubsub.logger.info "FastMcpPubsub: Listening on #{channel} for PID #{Process.pid}"
          @dedicated_connection.exec("LISTEN #{channel}")

          loop do
            break if @shutdown_requested

            @cleanup_counter = (@cleanup_counter || 0) + 1
            MessageStore.cleanup if (@cleanup_counter % 60).zero? # Every ~60s (1s per loop)

            @dedicated_connection.wait_for_notify(1) do |_channel, pid, payload|
              handle_notification(pid, payload)
            end
          end
        rescue StandardError => e
          unless @shutdown_requested
            FastMcpPubsub.logger.error "FastMcpPubsub: Listener error: #{e.message}"
            FastMcpPubsub.logger.error e.backtrace.join("\n")
            sleep 1
            retry
          end
        ensure
          begin
            @dedicated_connection&.exec("UNLISTEN #{channel}")
            @dedicated_connection&.close
          rescue StandardError => e
            FastMcpPubsub.logger.error "FastMcpPubsub: Error during cleanup: #{e.message}"
          end
          @dedicated_connection = nil
        end
      end

      def create_dedicated_connection
        db_config = ActiveRecord::Base.connection_db_config.configuration_hash

        conn_params = {
          host: db_config[:host],
          port: db_config[:port],
          dbname: db_config[:database],
          user: db_config[:username],
          password: db_config[:password]
        }.compact

        PG.connect(conn_params)
      end

      def handle_notification(pid, payload)
        FastMcpPubsub.logger.debug "FastMcpPubsub: Received notification from PID #{pid}: #{payload}"

        begin
          envelope = JSON.parse(payload)
          message = unwrap(envelope)
          return unless message # Reference already expired

          deliver_to_transports(message, target_of(envelope))
        rescue JSON::ParserError => e
          FastMcpPubsub.logger.error "FastMcpPubsub: Invalid JSON payload: #{e.message}"
        rescue StandardError => e
          FastMcpPubsub.logger.error "FastMcpPubsub: Error handling notification: #{e.message}"
        end
      end

      # The client this message is addressed to, or nil for a fan-out.
      def target_of(envelope)
        envelope["_pubsub_target"] if envelope.is_a?(Hash)
      end

      # Unwraps the three shapes that arrive on the channel: an inline message, a
      # database reference for one too large to fit in a NOTIFY, and a bare
      # JSON-RPC message with no envelope at all — which is what a worker still
      # running an older gem publishes during a rolling restart.
      def unwrap(envelope)
        return envelope unless envelope.is_a?(Hash)
        return envelope["_pubsub_message"] if envelope.key?("_pubsub_message")
        return envelope unless envelope.key?("_pubsub_ref")

        stored_payload = MessageStore.fetch(envelope["_pubsub_ref"])
        stored_payload && JSON.parse(stored_payload)
      end

      def deliver_to_transports(message, client_id = nil)
        # Find active RackTransport instances and send to local clients
        return unless defined?(FastMcp::Transports::RackTransport)

        transports = transport_instances
        FastMcpPubsub.logger.debug "FastMcpPubsub: Found #{transports.size} transport instances"

        transports.each do |transport|
          FastMcpPubsub.logger.debug "FastMcpPubsub: Sending message to transport #{transport.object_id}"
          next transport.send_local_message_to(client_id, message) if client_id

          transport.send_local_message(message)
        end
      end

      def transport_instances
        # Find all RackTransport instances - don't filter by running? since it's not reliably implemented
        ObjectSpace.each_object(FastMcp::Transports::RackTransport).to_a
      rescue StandardError
        []
      end
    end
  end
end
