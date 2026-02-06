# frozen_string_literal: true

module FastMcpPubsub
  # Core PostgreSQL NOTIFY/LISTEN service for broadcasting MCP messages across Puma workers
  class Service
    MAX_PAYLOAD_SIZE = 7800 # PostgreSQL NOTIFY limit is 8000 bytes, leave some margin

    class << self
      attr_reader :listener_thread, :dedicated_connection
      attr_accessor :shutdown_requested

      def broadcast(message)
        payload = message.to_json

        payload_too_large?(payload) ? broadcast_via_store(payload) : send_payload(payload)
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
        return unless @listener_thread&.alive?

        FastMcpPubsub.logger.info "FastMcpPubsub: Stopping listener thread for PID #{Process.pid}"
        @shutdown_requested = true

        # Cancel wait_for_notify to wake up the thread
        begin
          @dedicated_connection&.cancel
        rescue StandardError
          nil
        end

        @listener_thread.join(5) # Wait max 5 seconds
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

      def broadcast_via_store(payload)
        ref_id = MessageStore.store(payload)
        ref_payload = { _pubsub_ref: ref_id }.to_json
        FastMcpPubsub.logger.debug "FastMcpPubsub: Payload too large (#{payload.bytesize} bytes), stored as #{ref_id}"
        send_payload(ref_payload)
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
        PG.connect(
          host: db_config[:host] || "localhost",
          port: db_config[:port] || 5432,
          dbname: db_config[:database],
          user: db_config[:username],
          password: db_config[:password]
        )
      end

      def handle_notification(pid, payload)
        FastMcpPubsub.logger.debug "FastMcpPubsub: Received notification from PID #{pid}: #{payload}"

        begin
          message = JSON.parse(payload)

          # Resolve DB reference if present
          if message.is_a?(Hash) && message["_pubsub_ref"]
            stored_payload = MessageStore.fetch_and_delete(message["_pubsub_ref"])
            return unless stored_payload # Already consumed or expired

            message = JSON.parse(stored_payload)
          end

          deliver_to_transports(message)
        rescue JSON::ParserError => e
          FastMcpPubsub.logger.error "FastMcpPubsub: Invalid JSON payload: #{e.message}"
        rescue StandardError => e
          FastMcpPubsub.logger.error "FastMcpPubsub: Error handling notification: #{e.message}"
        end
      end

      def deliver_to_transports(message)
        # Find active RackTransport instances and send to local clients
        return unless defined?(FastMcp::Transports::RackTransport)

        transports = transport_instances
        FastMcpPubsub.logger.debug "FastMcpPubsub: Found #{transports.size} transport instances"

        transports.each do |transport|
          FastMcpPubsub.logger.debug "FastMcpPubsub: Sending message to transport #{transport.object_id}"
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
