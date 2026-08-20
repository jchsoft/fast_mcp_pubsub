# frozen_string_literal: true

module FastMcpPubsub
  # Thread-local record of which SSE client the request being served belongs to.
  #
  # FastMcp answers a JSON-RPC request over the client's SSE stream rather than in
  # the POST body, and MCP::Server#send_response has no idea which stream that is.
  # The transport does know: the client id arrives as a query parameter on the
  # POST. Stashing it here for the length of the request is what lets the response
  # be addressed instead of broadcast.
  #
  # A thread local is the right scope because FastMcp handles the POST
  # synchronously — handle_request calls send_response on the very thread that
  # entered handle_message_request_with_server, so the value set on the way in is
  # still there on the way out.
  module CurrentClient
    KEY = :fast_mcp_pubsub_client_id

    class << self
      # The client id of the request being served, or nil outside one — which is
      # what a genuine notification looks like, and those really are for everyone.
      def id
        Thread.current[KEY]
      end

      # Runs the block with client_id in scope, restoring whatever was there
      # before. Restoring rather than clearing keeps nesting honest; Puma reuses
      # its threads, and a stale id left behind would address the next request's
      # response to the previous request's client.
      def with(client_id)
        previous = Thread.current[KEY]
        Thread.current[KEY] = client_id
        yield
      ensure
        Thread.current[KEY] = previous
      end
    end
  end
end
