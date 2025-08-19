# frozen_string_literal: true

module FastMcpPubsub
  # Rails integration for automatic FastMcpPubsub setup and Puma cluster mode hooks
  class Railtie < Rails::Railtie
    # Start listener when Rails is ready
    initializer "fast_mcp_pubsub.start_listener" do |app|
      app.config.to_prepare do
        # Non-cluster mode initialization (rails server)
        # Only start if we're in a web server environment
        if (Rails.const_defined?("Server") || defined?(Puma) || ENV['MCP_SERVER_AUTO_START'] == 'true') &&
           FastMcpPubsub.config.enabled && 
           FastMcpPubsub.config.auto_start &&
           !@listener_started
          
          Rails.logger.info "FastMcpPubsub: Starting listener for non-cluster mode"
          FastMcpPubsub::Service.start_listener
          @listener_started = true
        end
      end
    end

    # Apply patch to FastMcp::Transports::RackTransport after all initializers are loaded
    initializer "fast_mcp_pubsub.apply_patch", after: :load_config_initializers do
      FastMcpPubsub.logger.debug "FastMcpPubsub: Attempting to apply RackTransport patch"
      FastMcpPubsub::RackTransportPatch.apply_patch!
    end

    # Puma worker boot hook for cluster mode
    initializer "fast_mcp_pubsub.puma_integration" do
      if defined?(Puma::Runner) && FastMcpPubsub.config.enabled
        # Register the listener to start on worker boot
        Puma::Runner.class_eval do
          alias_method :original_load_and_bind, :load_and_bind

          def load_and_bind
            result = original_load_and_bind

            # Add our worker boot hook
            if @config.options[:workers] && @config.options[:workers] > 1
              @config.on_worker_boot do
                if FastMcpPubsub.config.auto_start
                  FastMcpPubsub.logger.info "FastMcpPubsub: Starting PubSub listener for cluster mode worker #{Process.pid}"
                  FastMcpPubsub::Service.start_listener
                end
              end
            end

            result
          end
        end
      end
    end
  end
end
