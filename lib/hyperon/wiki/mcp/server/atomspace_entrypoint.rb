# frozen_string_literal: true

require "json"
require "mcp"
require_relative "tools/atomspace/registry"

module Hyperon
  module Wiki
    module Mcp
      module Server
        # The dedicated AtomSpace MCP entrypoint: one JSON-RPC request in, one
        # response out, served from the AtomSpace registry's own tool table and
        # authorized by the request's own captured grant.
        #
        # WHY A SEPARATE ENTRYPOINT RATHER THAN A FILTER ON THE PUBLIC ONE.
        # INTEGRATION.md step 2 (Card 17184, decision 2026-06-08, recorded there as
        # an acceptance criterion) requires the eight AtomSpace tools to live in a
        # dedicated toolset and never in the public Hyperon Wiki MCP tool list --
        # "not filtered or otherwise". A filter bolted onto the public server would
        # still make the public list the place those tools live, and would make the
        # Space-global aggregates (space_stats, atom_count_by_type, atom_types) one
        # misconfigured predicate away from the public surface. So the whole tool
        # table here IS Registry::TOOLS, and a public Deck tool is not reachable
        # through this path at all -- not denied, simply not in the table.
        #
        # WHY THE DENIAL IS A JSON-RPC ERROR AND NOT HTTP 401. A request that gets
        # this far has already authenticated: rack_app's fail-closed gate turned an
        # unauthenticated request into 401 before dispatch ever began. What can
        # still fail here is AUTHORIZATION -- the grant this request captured may
        # not name mcp:atomspace:read, or may have been read past its own
        # authorization deadline. Neither is fixed by presenting the credential
        # again, which is exactly what 401 instructs a client to do, so answering
        # 401 would send the caller into a retry loop over a decision that will not
        # change. The transport exchange succeeded; the authorization did not.
        #
        # AUTHORIZATION_DENIED is a local application code in the JSON-RPC
        # implementation-defined server-error range (-32000..-32099), chosen rather
        # than reused: rack_app already spends -32001 on "Authentication required"
        # and "Session not found", and collapsing authenticated-but-unauthorized
        # into that code would erase the distinction this entrypoint exists to make.
        # Unknown-tool and method-not-found follow the gem's own mapping
        # (MCP::Server raises :invalid_params for a tool it does not hold), because
        # those are routing facts, not authorization facts.
        #
        # LIST AND CALL ANSWER DIFFERENTLY, deliberately, inheriting the direction
        # the registry already established: visible_for_context builds the list
        # handed to every caller, so an unauthorized context gets an EMPTY list
        # rather than an error that denies tools/list to everybody;
        # gate_for_context! guards one invocation, so an unauthorized call is
        # DENIED. Both halves run -- visibility filtering alone is not enforcement
        # (INTEGRATION.md step 3) -- and the gate resolves its requirement from the
        # registered tool object, never from the name the request supplied.
        #
        # WHAT THIS DOES NOT DO. It decides nothing about which principals the deck
        # grants mcp:atomspace:read (owned by McpApi::AtomspaceGrants in the deck
        # repo, POLICY REV4), and it is not yet mounted on any HTTP path or stdio
        # transport. Nor is it reached by the gem's own inbound token now carrying
        # a signed `scope` claim (INTEGRATION.md step 1): that claim is issued and
        # verified by OAuth::TokenIssuer, whereas the grant consulted here comes
        # from Auth#read_grant against the DECK's token and the DECK's JWKS -- two
        # different credentials, and mcp:atomspace:read lives only in the latter.
        # Transport concerns are out of scope here on purpose: batched requests,
        # notification suppression for an id-less request, session handling, and
        # HTTP status mapping all belong to whichever slice mounts this, and this
        # module answers every request object it is handed.
        module AtomspaceEntrypoint
          # JSON-RPC implementation-defined server error (-32000..-32099): the
          # caller authenticated, and its own grant read does not authorize this
          # tool. Distinct from rack_app's -32001 "Authentication required".
          AUTHORIZATION_DENIED = -32_002
          AUTHORIZATION_DENIED_MESSAGE = "Authorization denied"

          # Routing, not authorization: this entrypoint serves the AtomSpace
          # registry's tools and holds nothing else. Mirrors the gem's own
          # tool-not-found mapping (MCP::Server -> :invalid_params -> -32602).
          UNKNOWN_TOOL = -32_602
          UNKNOWN_TOOL_MESSAGE = "Unknown tool"

          METHOD_NOT_FOUND = -32_601
          METHOD_NOT_FOUND_MESSAGE = "Method not found"

          INVALID_PARAMS = -32_602
          INVALID_PARAMS_MESSAGE = "Invalid params"

          TOOLS_LIST = "tools/list"
          TOOLS_CALL = "tools/call"

          module_function

          # Answer one parsed JSON-RPC request.
          #
          # @param request [Hash] a parsed JSON-RPC request object; string or symbol
          #   keys, because a parsed HTTP body supplies either.
          # @param context [RequestContext, nil] the request's own captured context.
          #   nil is the fail-closed answer rack_app's #build_request_context
          #   already returns when no grant backs the request, and is treated here
          #   as "nothing was authorized" -- never as permission.
          # @param server_context [Hash] the MCP server context a tool call runs
          #   under (carries :magi_tools).
          # @param now [Time] the clock the authorization deadline is read against.
          def handle(request, context:, server_context:, now: Time.now)
            id = field(request, :id)

            case field(request, :method)
            when TOOLS_LIST
              success(id, { tools: visible_tool_descriptors(context, now) })
            when TOOLS_CALL
              handle_call(field(request, :params), id, context, server_context, now)
            else
              failure(id, METHOD_NOT_FOUND, METHOD_NOT_FOUND_MESSAGE,
                      { method: field(request, :method) })
            end
          end

          # The advertised list: whatever this context's own grant read authorizes,
          # which for an unauthorized context is nothing.
          def visible_tool_descriptors(context, now)
            Tools::Atomspace::Registry.visible_for_context(context, now: now).map(&:to_h)
          end

          # Resolve, gate, then invoke -- in that order, and the order matters.
          #
          # Resolution first because the gate must be asked about a REGISTERED tool
          # object rather than a free-form request name; a name this entrypoint does
          # not hold is a routing answer and says nothing about what the caller
          # holds. The gate next, so a denied call never reaches the deck -- a
          # denial that still performed the read would have leaked exactly what it
          # refused.
          def handle_call(params, id, context, server_context, now)
            tool = resolve_tool(field(params, :name))
            return failure(id, UNKNOWN_TOOL, UNKNOWN_TOOL_MESSAGE, { tool: field(params, :name) }) unless tool

            begin
              Tools::Atomspace::Registry.gate_for_context!(tool, context, now: now)
            rescue Client::AuthorizationError => e
              return failure(id, AUTHORIZATION_DENIED, AUTHORIZATION_DENIED_MESSAGE,
                             { tool: tool.name_value, reason: e.message })
            end

            invoke(tool, field(params, :arguments), id, server_context)
          end

          # Only the registry's own tools, matched on the name the gem advertises.
          def resolve_tool(name)
            return nil unless name.is_a?(String) && !name.empty?

            Tools::Atomspace::Registry::TOOLS.find { |tool| tool.name_value == name }
          end

          # The gem's own required-argument check, kept so a malformed call answers
          # "invalid params" rather than raising ArgumentError out of a keyword
          # mismatch. Schema-shape validation beyond required-presence is left to
          # the mounting slice, which is where the gem's configuration lives.
          def invoke(tool, arguments, id, server_context)
            args = symbolize(arguments)
            schema = tool.input_schema
            if schema.respond_to?(:missing_required_arguments?) && schema.missing_required_arguments?(args)
              missing = schema.missing_required_arguments(args).join(", ")
              return failure(id, INVALID_PARAMS, INVALID_PARAMS_MESSAGE,
                             { tool: tool.name_value, missing: missing })
            end

            success(id, tool.call(**args, server_context: server_context).to_h)
          end

          # A parsed body arrives with string keys over HTTP and symbol keys from an
          # in-process caller; both name the same field.
          def field(source, key)
            return nil unless source.is_a?(Hash)

            source.key?(key) ? source[key] : source[key.to_s]
          end

          def symbolize(arguments)
            return {} unless arguments.is_a?(Hash)

            arguments.transform_keys(&:to_sym)
          end

          def success(id, result)
            { jsonrpc: "2.0", id: id, result: result }
          end

          def failure(id, code, message, data = nil)
            error = { code: code, message: message }
            error[:data] = data if data
            { jsonrpc: "2.0", id: id, error: error }
          end
        end
      end
    end
  end
end
