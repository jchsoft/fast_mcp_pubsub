# frozen_string_literal: true

require "test_helper"

class TestService < Minitest::Test
  def setup
    FastMcpPubsub.configuration = nil # Reset configuration
    @service = FastMcpPubsub::Service
  end

  def teardown
    @service.stop_listener if @service.listener_thread&.alive?
    FastMcpPubsub.configuration = nil
  end

  def test_broadcast_small_message
    message = { id: 1, method: "test", params: {} }

    # Should not raise error with ActiveRecord mocked
    @service.broadcast(message)
    # Just testing it doesn't crash
  end

  def test_broadcast_large_message_creates_error_response
    large_content = "x" * 8000
    message = { id: 1, method: "test", params: { content: large_content } }

    # Mock the send_payload method to capture what gets sent
    sent_payloads = []
    @service.define_singleton_method(:send_payload) do |payload|
      sent_payloads << JSON.parse(payload)
    end

    @service.broadcast(message)

    # Should have sent an error response
    assert_equal 1, sent_payloads.size
    error_response = sent_payloads.first

    assert_equal "2.0", error_response["jsonrpc"]
    assert_equal 1, error_response["id"]
    assert error_response["error"]
    assert_equal(-32_001, error_response["error"]["code"])
    assert_includes error_response["error"]["message"], "too large"

    # Restore original method
    @service.singleton_class.send(:remove_method, :send_payload)
  end

  def test_start_listener_when_enabled
    FastMcpPubsub.configure { |c| c.enabled = true }

    refute @service.listener_thread&.alive?

    @service.start_listener

    assert @service.listener_thread
    # Give thread time to start
    sleep 0.1
    # NOTE: Thread might not be alive in test because of mocked wait_for_notify
  end

  def test_start_listener_when_disabled
    FastMcpPubsub.configure { |c| c.enabled = false }

    @service.start_listener

    refute @service.listener_thread&.alive?
  end

  def test_stop_listener
    FastMcpPubsub.configure { |c| c.enabled = true }

    @service.start_listener
    @service.stop_listener

    # Thread should be stopped
    refute @service.listener_thread&.alive?
  end

  def test_handle_notification_with_valid_json
    message = { id: 1, method: "test" }
    payload = message.to_json

    # Mock transport instances
    mock_transport = Minitest::Mock.new
    parsed_message = JSON.parse(payload)
    mock_transport.expect(:send_local_message, nil, [parsed_message])

    @service.define_singleton_method(:transport_instances) do
      [mock_transport]
    end

    # Call handle_notification (private method)
    @service.send(:handle_notification, "test_channel", 123, payload)

    mock_transport.verify

    # Clean up
    @service.singleton_class.send(:remove_method, :transport_instances)
  end

  def test_handle_notification_with_invalid_json
    # Should not raise error with invalid JSON
    assert_silent do
      @service.send(:handle_notification, "test_channel", 123, "invalid json")
    end
  end

  def test_payload_size_limit
    small_payload = "x" * 100
    large_payload = "x" * 8000

    refute @service.send(:payload_too_large?, small_payload)
    assert @service.send(:payload_too_large?, large_payload)
  end
end
