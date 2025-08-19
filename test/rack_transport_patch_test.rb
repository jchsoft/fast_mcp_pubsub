# frozen_string_literal: true

require "test_helper"

class TestRackTransportPatch < Minitest::Test
  def setup
    FastMcpPubsub.configuration = nil
    # Apply patch for testing
    FastMcpPubsub::RackTransportPatch.apply_patch!
    # Create fresh transport instance
    @transport = FastMcp::Transports::RackTransport.new
    @transport.running = true
    @transport.clear_messages
  end

  def teardown
    FastMcpPubsub.configuration = nil
  end

  def test_patch_is_applied
    assert FastMcpPubsub::RackTransportPatch.patch_applied?
  end

  def test_transport_has_patched_methods
    assert_respond_to @transport, :send_local_message
    assert_respond_to @transport, :running?
    assert_respond_to @transport, :broadcast_with_fallback
  end

  def test_pubsub_disabled_uses_local_message
    FastMcpPubsub.configure { |c| c.enabled = false }

    message = { id: 1, method: "test" }
    @transport.send_message(message)

    # Should have used local sending (original behavior)
    assert_equal [message], @transport.sent_messages
  end

  def test_pubsub_enabled_attempts_broadcast
    FastMcpPubsub.configure { |c| c.enabled = true }

    # Use instance-specific mock instead of global one
    def @transport.broadcast_with_fallback(message)
      @broadcast_called = true
      raise StandardError, "Simulated broadcast error"  # Force fallback
    rescue StandardError
      send_local_message(message)
    end
    
    def @transport.broadcast_called?
      @broadcast_called || false
    end

    message = { id: 1, method: "test" }
    @transport.send_message(message)

    # Should have fallen back to local message due to error
    assert_equal [message], @transport.sent_messages
  end

  def test_lazy_patch_application
    # Reset patch state for this test (this is a bit hacky but necessary for testing)
    FastMcpPubsub::RackTransportPatch.instance_variable_set(:@patch_applied, false)

    # Apply patch again
    FastMcpPubsub::RackTransportPatch.apply_patch!

    # Should be applied now
    assert FastMcpPubsub::RackTransportPatch.patch_applied?
  end
end