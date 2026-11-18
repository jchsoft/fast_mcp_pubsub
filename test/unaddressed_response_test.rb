# frozen_string_literal: true

require "test_helper"
require "rack"

# A response nobody can address is never fanned out. A POST without client_id
# used to leave no client in scope, and its answer went to every SSE client on
# every worker: one client's data in everybody's stream.
class TestUnaddressedResponse < Minitest::Test
  include BroadcastCapture
  include LogCapture

  def setup
    FastMcpPubsub.configuration = nil
    FastMcpPubsub::RackTransportPatch.apply_patch!
    @transport = FastMcp::Transports::RackTransport.new
    @transport.clear_messages
  end

  def teardown
    FastMcpPubsub.configuration = nil
  end

  def test_a_post_without_client_id_is_refused_as_a_bad_request
    status, _headers, body = handle(post("/mcp/messages"))

    assert_equal 400, status
    assert_equal(-32_600, JSON.parse(body.first).dig("error", "code"))
  end

  def test_a_refused_post_never_reaches_the_server
    handle(post("/mcp/messages?client_id="))

    assert_empty @transport.handled_requests, "running it would produce a response with nowhere safe to go"
  end

  def test_the_refusal_names_the_caller
    log = capture_log { handle(post("/mcp/messages", "REMOTE_ADDR" => "203.0.113.9", "HTTP_USER_AGENT" => "stale-client/0.1")) }

    assert_includes log, "Refused POST /mcp/messages without client_id from 203.0.113.9 (stale-client/0.1)"
  end

  def test_a_post_with_client_id_runs
    handle(post("/mcp/messages?client_id=client-a"))

    assert_equal 1, @transport.handled_requests.size
  end

  def test_a_response_with_no_client_in_scope_raises
    error = assert_raises(FastMcpPubsub::UnaddressedResponseError) { @transport.send_message({ jsonrpc: "2.0", id: 7, result: {} }) }

    assert_includes error.message, "id=7"
  end

  def test_an_unaddressed_response_is_published_to_nobody
    payloads = capture_payloads { send_unaddressed({ jsonrpc: "2.0", id: 7, result: { secret: "a" } }) }

    assert_empty payloads
    assert_empty @transport.sent_messages
  end

  def test_an_unaddressed_error_response_raises_too
    assert_raises(FastMcpPubsub::UnaddressedResponseError) { @transport.send_message({ jsonrpc: "2.0", id: nil, error: { code: -32_603 } }) }
  end

  def test_an_unaddressed_response_given_as_json_raises_too
    assert_raises(FastMcpPubsub::UnaddressedResponseError) { @transport.send_message('{"jsonrpc":"2.0","id":7,"result":{}}') }
  end

  def test_an_unaddressed_response_reaches_nobody_with_pubsub_disabled
    FastMcpPubsub.configure { |config| config.enabled = false }

    send_unaddressed({ jsonrpc: "2.0", id: 7, result: {} })

    assert_empty @transport.sent_messages, "the local fan-out would leak it just the same"
  end

  def test_a_notification_with_no_client_still_fans_out
    payloads = capture_payloads { @transport.send_message({ jsonrpc: "2.0", method: "notifications/resources/updated", params: { uri: "x" } }) }

    refute JSON.parse(payloads.first).key?("_pubsub_target"), "a notification really is for everyone"
  end

  def test_an_addressed_response_reaches_only_its_client_with_pubsub_disabled
    FastMcpPubsub.configure { |config| config.enabled = false }
    mine = FakeSseStream.new
    theirs = FakeSseStream.new
    @transport.register_sse_client("client-a", mine)
    @transport.register_sse_client("client-b", theirs)

    FastMcpPubsub::CurrentClient.with("client-a") { @transport.send_message({ id: 1, result: "secret" }) }

    assert_equal ["data: {\"id\":1,\"result\":\"secret\"}\n\n"], mine.writes
    assert_empty theirs.writes, "the other session must never see this answer"
  end

  private

  def post(path, env = {})
    Rack::Request.new(Rack::MockRequest.env_for(path, { method: "POST", input: "{}" }.merge(env)))
  end

  def handle(request)
    @transport.send(:handle_message_request_with_server, request, :server)
  end

  # Sends a response expected to be refused, for the tests that look at where it went.
  def send_unaddressed(message)
    @transport.send_message(message)
  rescue FastMcpPubsub::UnaddressedResponseError
    nil
  end
end
