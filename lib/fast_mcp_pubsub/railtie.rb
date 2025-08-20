# frozen_string_literal: true

module FastMcpPubsub
  # Rails integration for automatic FastMcpPubsub setup and Puma cluster mode hooks
  class Railtie < Rails::Railtie
    # Start listener when Rails is ready
    initializer "fast_mcp_pubsub.start_listener" do |app|
      railtie = self
      app.config.to_prepare do
        # Non-cluster mode initialization (rails server)
        # Only start if we're in a web server environment
        if railtie.send(:should_start_listener?)
          Rails.logger.info "FastMcpPubsub: Starting listener for non-cluster mode"
          FastMcpPubsub::Service.start_listener
          railtie.instance_variable_set(:@listener_started, true)
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
      FastMcpPubsub.logger.info "FastMcpPubsub: Puma integration initializer - enabled: #{FastMcpPubsub.config.enabled}, auto_start: #{FastMcpPubsub.config.auto_start}, Puma defined: #{defined?(Puma::Runner)}"

      if defined?(Puma::Runner) && FastMcpPubsub.config.enabled
        FastMcpPubsub.logger.info "FastMcpPubsub: Setting up Puma integration"
        # Register the listener to start on worker boot
        Puma::Runner.class_eval do
          alias_method :original_load_and_bind, :load_and_bind

          def load_and_bind
            original_load_and_bind.tap do
              # Add our worker boot hook
              workers = @config.options[:workers]
              FastMcpPubsub.logger.info "FastMcpPubsub: Puma workers configured: #{workers}"

              if workers && workers > 1
                FastMcpPubsub.logger.info "FastMcpPubsub: Adding worker boot hook for cluster mode"
                @config.on_worker_boot do
                  FastMcpPubsub.logger.info "FastMcpPubsub: Worker boot hook executing for PID #{Process.pid}, auto_start: #{FastMcpPubsub.config.auto_start}"
                  if FastMcpPubsub.config.auto_start
                    FastMcpPubsub.logger.info "FastMcpPubsub: Starting PubSub listener for cluster mode worker #{Process.pid}"
                    FastMcpPubsub::Service.start_listener
                  else
                    FastMcpPubsub.logger.info "FastMcpPubsub: Not starting listener - auto_start is disabled for PID #{Process.pid}"
                  end
                end
              else
                FastMcpPubsub.logger.info "FastMcpPubsub: Not cluster mode, skipping worker boot hook"
              end
            end
          end
        end
      else
        FastMcpPubsub.logger.info "FastMcpPubsub: Puma integration skipped - Puma not defined or disabled"
      end
    end

    private

    def should_start_listener?
      web_server_environment? &&
        FastMcpPubsub.config.enabled &&
        FastMcpPubsub.config.auto_start &&
        !instance_variable_get(:@listener_started)
    end

    def web_server_environment?
      Rails.const_defined?("Server") || defined?(Puma) || ENV["MCP_SERVER_AUTO_START"] == "true"
    end
  end
end
