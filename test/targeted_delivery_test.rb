# frozen_string_literal: true

require "test_helper"

# A response belongs to the client that asked for it. Before addressing existed,
# every JSON-RPC response was written into every open SSE stream on the server,
# and the only thing keeping clients apart was JSON-RPC id matching — which fails
# the moment two clients open fresh sessions at the same minute and both start
# counting from 1.
class TestTargetedDelivery < Minitest::Test
  # Records what was written to one client's stream.
  class FakeStream
    attr_reader :writes

    def initialize
      @writes = []
    end

    def write(data)
      @writes << data
    end

    def flush; end

    def closed?
      false
    end
  end

  def setup
    FastMcpPubsub.configuration = nil
    FastMcpPubsub::RackTransportPatch.apply_patch!
    @transport = FastMcp::Transports::RackTransport.new
    @transport.running = true
    @transport.clear_messages
  end

  def teardown
    FastMcpPubsub.configuration = nil
    FastMcpPubsub::CurrentClient.with(nil) { nil }
  end

  def test_current_client_is_scoped_to_the_block
    assert_nil FastMcpPubsub::CurrentClient.id

    FastMcpPubsub::CurrentClient.with("client-a") do
      assert_equal "client-a", FastMcpPubsub::CurrentClient.id
    end

    assert_nil FastMcpPubsub::CurrentClient.id, "a stale id would address the next request's response"
  end

  def test_current_client_restores_the_outer_value
    FastMcpPubsub::CurrentClient.with("outer") do
      FastMcpPubsub::CurrentClient.with("inner") { nil }

      assert_equal "outer", FastMcpPubsub::CurrentClient.id
    end
  end

  def test_query_with_client_id_appends_to_an_existing_query
    query = FastMcpPubsub::AddressingPatch.query_with_client_id("token=abc", "client-a")

    assert_equal "token=abc&client_id=client-a", query
  end

  def test_query_with_client_id_handles_an_empty_query
    assert_equal "client_id=client-a", FastMcpPubsub::AddressingPatch.query_with_client_id(nil, "client-a")
    assert_equal "client_id=client-a", FastMcpPubsub::AddressingPatch.query_with_client_id("", "client-a")
  end

  def test_query_with_client_id_leaves_a_client_supplied_id_alone
    query = FastMcpPubsub::AddressingPatch.query_with_client_id("client_id=theirs", "ours")

    assert_equal "client_id=theirs", query, "FastMcp honours the client's own id; overriding it would split the session"
  end

  def test_endpoint_url_carries_the_client_id
    @transport.send(:setup_sse_connection, "client-a", nil, { "QUERY_STRING" => "token=abc" })

    assert_equal ["token=abc&client_id=client-a"], @transport.endpoint_queries
  end

  def test_the_post_puts_its_client_in_scope
    request = Minitest::Mock.new
    request.expect(:GET, { "client_id" => "client-a" })

    _, _, seen = @transport.send(:handle_message_request_with_server, request, :server)

    assert_equal "client-a", seen
    assert_nil FastMcpPubsub::CurrentClient.id
  end

  def test_targeted_send_reaches_only_the_named_client
    mine = FakeStream.new
    theirs = FakeStream.new
    @transport.register_sse_client("client-a", mine)
    @transport.register_sse_client("client-b", theirs)

    @transport.send_local_message_to("client-a", { id: 1, result: "secret" })

    assert_equal ["data: {\"id\":1,\"result\":\"secret\"}\n\n"], mine.writes
    assert_empty theirs.writes, "the other session must never see this answer"
  end

  def test_targeted_send_reports_a_client_this_worker_does_not_hold
    refute @transport.send_local_message_to("client-elsewhere", { id: 1 })
  end

  def test_broadcast_addresses_the_envelope
    payloads = capture_payloads { FastMcpPubsub::Service.broadcast({ id: 1, result: "ok" }, "client-a") }

    envelope = JSON.parse(payloads.first)

    assert_equal "client-a", envelope["_pubsub_target"]
    assert_equal({ "id" => 1, "result" => "ok" }, envelope["_pubsub_message"])
  end

  def test_broadcast_without_a_client_carries_no_target
    payloads = capture_payloads { FastMcpPubsub::Service.broadcast({ method: "notifications/resources/updated" }) }

    refute JSON.parse(payloads.first).key?("_pubsub_target"), "a notification really is for everyone"
  end

  def test_an_addressed_notification_is_delivered_to_that_client_only
    transport = Minitest::Mock.new
    transport.expect(:send_local_message_to, true, ["client-a", { "id" => 1 }])

    deliver(transport, { _pubsub_target: "client-a", _pubsub_message: { id: 1 } }.to_json)

    transport.verify
  end

  def test_an_unaddressed_notification_still_fans_out
    transport = Minitest::Mock.new
    transport.expect(:send_local_message, nil, [{ "id" => 1 }])

    deliver(transport, { _pubsub_message: { id: 1 } }.to_json)

    transport.verify
  end

  # A worker still running the previous gem publishes a bare JSON-RPC message
  # during a rolling restart. It has no target and must keep working.
  def test_a_legacy_payload_without_an_envelope_still_fans_out
    transport = Minitest::Mock.new
    transport.expect(:send_local_message, nil, [{ "id" => 1, "result" => "ok" }])

    deliver(transport, { id: 1, result: "ok" }.to_json)

    transport.verify
  end

  def test_send_message_addresses_the_response_of_the_request_in_scope
    payloads = capture_payloads do
      FastMcpPubsub::CurrentClient.with("client-a") { @transport.send_message({ id: 1, result: "ok" }) }
    end

    assert_equal "client-a", JSON.parse(payloads.first)["_pubsub_target"]
  end

  private

  def capture_payloads(&)
    payloads = []
    FastMcpPubsub::Service.stub(:send_payload, ->(payload) { payloads << payload }, &)
    payloads
  end

  def deliver(transport, payload)
    FastMcpPubsub::Service.stub(:transport_instances, [transport]) do
      FastMcpPubsub::Service.send(:handle_notification, 123, payload)
    end
  end
end
