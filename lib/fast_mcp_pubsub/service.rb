# frozen_string_literal: true

module FastMcpPubsub
  # Core PostgreSQL NOTIFY/LISTEN service for broadcasting MCP messages across Puma workers
  class Service
    MAX_PAYLOAD_SIZE = 7800 # PostgreSQL NOTIFY limit is 8000 bytes, leave some margin

    class << self
      include Delivery

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

        wake_listener
        join_listener
        discard_dedicated_connection
        @shutdown_requested = false
      end

      private

      # Cancels the in-flight wait_for_notify so the thread reaches its next
      # shutdown check instead of sitting out the rest of the timeout.
      def wake_listener
        @dedicated_connection&.cancel
      rescue StandardError
        nil
      end

      # Five seconds to notice, then it is taken down: a thread stuck inside
      # PG.connect during a reconnect never notices on its own.
      def join_listener
        @listener_thread.join(5)

        if @listener_thread&.alive?
          @listener_thread.kill
          @listener_thread.join(1)
        end

        @listener_thread = nil
      end

      def discard_dedicated_connection
        @dedicated_connection&.close
      rescue StandardError
        nil
      ensure
        @dedicated_connection = nil
      end

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

      # The listener thread's whole life. `retry` re-enters the begin block
      # without running the ensure, which is what lets a reconnect keep the
      # LISTEN it is about to re-establish — so the split below has to keep the
      # begin/rescue/ensure here rather than push it into a helper.
      def listen_loop
        channel = FastMcpPubsub.config.channel_name

        begin
          open_listener(channel)
          consume_notifications
        rescue StandardError => e
          retry if listener_should_recover?(e)
        ensure
          close_listener(channel)
        end
      end

      def open_listener(channel)
        @dedicated_connection = create_dedicated_connection

        FastMcpPubsub.logger.info "FastMcpPubsub: Listening on #{channel} for PID #{Process.pid}"
        @dedicated_connection.exec("LISTEN #{channel}")
      end

      def consume_notifications
        loop do
          break if @shutdown_requested

          @cleanup_counter = (@cleanup_counter || 0) + 1
          MessageStore.cleanup if (@cleanup_counter % 60).zero? # Every ~60s (1s per loop)

          @dedicated_connection.wait_for_notify(1) do |_channel, pid, payload|
            handle_notification(pid, payload)
          end
        end
      end

      # Reports whether the loop should come back up, having logged and paused if
      # so. A shutdown in progress is not an error to recover from — it is the
      # exit, and the error is the connection being cancelled out from under us.
      def listener_should_recover?(error)
        return false if @shutdown_requested

        FastMcpPubsub.logger.error "FastMcpPubsub: Listener error: #{error.message}"
        FastMcpPubsub.logger.error error.backtrace.join("\n")
        sleep 1
        true
      end

      def close_listener(channel)
        @dedicated_connection&.exec("UNLISTEN #{channel}")
        @dedicated_connection&.close
      rescue StandardError => e
        FastMcpPubsub.logger.error "FastMcpPubsub: Error during cleanup: #{e.message}"
      ensure
        @dedicated_connection = nil
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
    end
  end
end
