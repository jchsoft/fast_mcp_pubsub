# frozen_string_literal: true

require "test_helper"
require "socket"

# A client that vanishes without closing its TCP connection leaves a write to it
# blocked until TCP gives up, which took 56 s in production. That write runs on
# the worker's PubSub listener thread, so every SSE response on the worker
# waited behind it. The write timeout turns the stall into a disconnect.
class TestSseWriteTimeout < Minitest::Test
  include LogCapture

  def setup
    FastMcpPubsub.configuration = nil
    FastMcpPubsub::RackTransportPatch.apply_patch!
    @transport = FastMcp::Transports::RackTransport.new
    @listener = TCPServer.new("127.0.0.1", 0)
    @peer = TCPSocket.new("127.0.0.1", @listener.addr[1]) # connected, and never reads
    @io = @listener.accept
  end

  def teardown
    [@io, @peer, @listener].each(&:close)
    FastMcpPubsub.configuration = nil
  end

  def test_the_default_timeout_is_ten_seconds
    assert_equal 10, FastMcpPubsub::Configuration.new.sse_write_timeout
  end

  def test_the_sse_connection_gets_the_configured_timeout
    FastMcpPubsub.configure { |config| config.sse_write_timeout = 3 }

    connect

    assert_equal 3, @io.timeout
  end

  def test_a_client_that_stopped_reading_is_dropped_after_the_timeout
    FastMcpPubsub.configure { |config| config.sse_write_timeout = 1 }
    connect

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    delivered = @transport.send_local_message_to("client-a", { id: 1, result: "x" * 16_000_000 })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute delivered
    assert_operator elapsed, :<, 3, "the write must give up after the timeout, not when TCP does"
    refute @transport.sse_clients.key?("client-a"), "a client that cannot be written to must be unregistered"
  end

  def test_an_io_that_takes_no_timeout_is_reported
    log = capture_log { @transport.send(:setup_sse_connection, "client-a", Object.new, { "QUERY_STRING" => "" }) }

    assert_includes log, "Object takes no write timeout"
  end

  private

  def connect
    @transport.send(:setup_sse_connection, "client-a", @io, { "QUERY_STRING" => "" })
    @transport.register_sse_client("client-a", @io)
  end
end
