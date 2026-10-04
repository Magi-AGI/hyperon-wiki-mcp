# frozen_string_literal: true

require "json_rpc_handler"
require_relative "atomspace_entrypoint"

module Hyperon
  module Wiki
    module Mcp
      module Server
        # The JSON-RPC envelope around the dedicated AtomSpace entrypoint: request-shape
        # validation, batching, and notification suppression.
        #
        # WHY THIS EXISTS AS ITS OWN LAYER. AtomspaceEntrypoint answers exactly one parsed
        # request object and says so deliberately -- batching, id-less notifications, and
        # request-shape validation "belong to whichever slice mounts this". This is that half,
        # kept out of both neighbours: out of the entrypoint, so the authorization decision
        # stays readable beside nothing else; and out of rack_app, so a second transport (a
        # future stdio variant, say) can reach the same rules without going through Rack.
        #
        # WHY EVERY STRUCTURAL ANSWER IS THE GEM'S OWN. The public path reaches
        # JsonRpcHandler.handle through MCP::Server#handle, so this host ALREADY answers an
        # empty batch, a wrong `jsonrpc`, an unusable id, a non-object `params`, and an id-less
        # notification in a particular way. A second path on the same host answering any of
        # them differently would be a second protocol dialect -- a client could not write one
        # correct request for both. So every refusal below is produced by JsonRpcHandler's own
        # predicates (#valid_version?, #valid_id?, #valid_method_name?, #valid_params?), its
        # own error codes, and its own #error_response builder, and the equivalence is asserted
        # directly against JsonRpcHandler.handle in spec/server/atomspace_json_rpc_spec.rb.
        #
        # WHY JsonRpcHandler IS NOT USED TO BUILD THE WHOLE RESPONSE, which would be the
        # obvious shortcut. JsonRpcHandler.handle constructs the response envelope itself from
        # whatever the method block returns, and can express only the five standard JSON-RPC
        # error codes: its MCP::Server::RequestHandlerError mapping covers :invalid_request,
        # :invalid_params, :parse_error and :internal_error, and nothing else. The
        # authorization denial this toolset exists to make is -32002, in the
        # implementation-defined server-error range, which that mapping cannot carry at all.
        # So the entrypoint keeps producing whole envelopes, including its own error ones, and
        # this module supplies only the structure around them.
        #
        # ONE DELIBERATE DIFFERENCE, named because it is a difference. A non-Hash element
        # inside a batch: JsonRpcHandler maps #process_request over the array unguarded, so a
        # String member raises TypeError out of `request[:id]`. This module answers Invalid
        # Request instead -- the same code, message and null id the gem itself uses for a
        # non-Hash request at top level, so it introduces no vocabulary the public path does
        # not already speak.
        #
        # NOT HERE: HTTP status mapping, session handling, and the authentication gate, all of
        # which are the Rack mount's (see RackApp#handle_atomspace_message). This module
        # neither knows nor cares that a request arrived over HTTP.
        module AtomspaceJsonRpc
          # The gem's own id grammar, referenced rather than copied. A dedicated path that
          # accepted ids the public path rejects would be the dialect problem above in its
          # smallest form.
          ID_VALIDATION_PATTERN = ::JsonRpcHandler::DEFAULT_ALLOWED_ID_CHARACTERS

          # JsonRpcHandler's own sentinel for "no usable id could be read from this request".
          # Handed to its #error_response so a structurally broken request is still ANSWERED
          # -- the sentinel is not nil, so the notification suppression inside that builder
          # does not fire -- while the envelope reports a null id. Exactly what the public
          # path does with the same input.
          UNKNOWN_ID = :unknown_id

          # JsonRpcHandler's structural complaints, in its wording. Restated as constants
          # because the gem writes them inline in #process_request and exposes none; the spec
          # compares every answer below to JsonRpcHandler.handle's answer for the same input,
          # so a drift in either direction fails there rather than reaching a client.
          WRONG_VERSION = "JSON-RPC version must be 2.0"
          UNUSABLE_ID = "Request ID must match validation pattern, or be an integer or null"
          UNUSABLE_METHOD = 'Method name must be a string and not start with "rpc."'
          UNUSABLE_PARAMS = "Method parameters must be an array or an object or null"
          NOT_A_REQUEST = "Request must be an array or a hash"
          EMPTY_BATCH = "Request is an empty array"

          INVALID_REQUEST_MESSAGE = "Invalid Request"
          INVALID_PARAMS_MESSAGE = "Invalid params"

          module_function

          # Answer one parsed JSON-RPC payload: a request object, or a batch of them.
          #
          # @param request [Hash, Array] the parsed payload. Anything else is refused as the
          #   gem refuses it, rather than raised on.
          # @param context [RequestContext, nil] this request's own captured context, passed
          #   through untouched. nil is the fail-closed answer rack_app already produces when
          #   no grant backs the request.
          # @param server_context [Hash] the context a tool call runs under (carries
          #   :magi_tools).
          # @param now [Time] the clock the authorization deadline is read against.
          # @return [Hash, Array, nil] one envelope, a batch of envelopes, or nil when every
          #   request in the payload was a notification.
          def dispatch(request, context:, server_context:, now: Time.now)
            if request.is_a?(Array)
              dispatch_batch(request, context, server_context, now)
            elsif request.is_a?(Hash)
              dispatch_one(request, context, server_context, now)
            else
              invalid_request(NOT_A_REQUEST)
            end
          end

          # Batch handling, inherited whole: an empty array is Invalid Request, a
          # single-element batch is HOISTED OUT of its array, notifications are dropped from
          # the results, and a batch of nothing but notifications answers nothing at all.
          def dispatch_batch(requests, context, server_context, now)
            return invalid_request(EMPTY_BATCH) if requests.empty?

            responses = requests.filter_map { |member| dispatch_member(member, context, server_context, now) }

            return responses.first if responses.one?

            responses if responses.any?
          end

          # The one place this layer is kinder than the gem: see ONE DELIBERATE DIFFERENCE.
          def dispatch_member(member, context, server_context, now)
            return invalid_request(NOT_A_REQUEST) unless member.is_a?(Hash)

            dispatch_one(member, context, server_context, now)
          end

          # Validate the shape, then let the entrypoint decide. The order matters: a request
          # that is not a well-formed JSON-RPC call must never reach the tool table, and above
          # all must not reach the deck.
          def dispatch_one(request, context, server_context, now)
            refusal = structural_refusal(request)
            return refusal if refusal

            answer(
              AtomspaceEntrypoint.handle(request, context: context, server_context: server_context, now: now),
              request_id(request)
            )
          end

          # Notification suppression, as JsonRpcHandler does it rather than as a rule of our
          # own: its #success_response and #error_response both return nil when the id is nil,
          # so an id-less request is answered with nothing. The WORK still happens -- the gem
          # calls the method and then discards the envelope, and so does this.
          def answer(envelope, id)
            id.nil? ? nil : envelope
          end

          # nil when the request is well-formed, otherwise the envelope refusing it.
          def structural_refusal(request)
            complaint = request_complaint(request)
            return invalid_request(complaint) if complaint
            return nil if ::JsonRpcHandler.valid_params?(field(request, :params))

            ::JsonRpcHandler.error_response(
              id: request_id(request), id_validation_pattern: ID_VALIDATION_PATTERN,
              error: { code: ::JsonRpcHandler::ErrorCode::INVALID_PARAMS,
                       message: INVALID_PARAMS_MESSAGE, data: UNUSABLE_PARAMS }
            )
          end

          # The three complaints JsonRpcHandler makes before it will look for a method, in its
          # order. Order is preserved because the gem reports only the FIRST, and a request
          # with two faults must get the same single answer from both paths.
          def request_complaint(request)
            return WRONG_VERSION unless ::JsonRpcHandler.valid_version?(field(request, :jsonrpc))
            return UNUSABLE_ID unless ::JsonRpcHandler.valid_id?(request_id(request), ID_VALIDATION_PATTERN)
            return UNUSABLE_METHOD unless ::JsonRpcHandler.valid_method_name?(field(request, :method))

            nil
          end

          def invalid_request(data)
            ::JsonRpcHandler.error_response(
              id: UNKNOWN_ID, id_validation_pattern: ID_VALIDATION_PATTERN,
              error: { code: ::JsonRpcHandler::ErrorCode::INVALID_REQUEST,
                       message: INVALID_REQUEST_MESSAGE, data: data }
            )
          end

          def request_id(request)
            field(request, :id)
          end

          # The ENTRYPOINT's field reader, not a second copy of it. Both layers must read a
          # field the same way or they will disagree about one request: a suppression rule
          # that read a symbol :id while the entrypoint echoed a string "id" would silently
          # drop answers to perfectly good requests.
          def field(source, key)
            AtomspaceEntrypoint.field(source, key)
          end
        end
      end
    end
  end
end
