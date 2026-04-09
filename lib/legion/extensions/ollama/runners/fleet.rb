# frozen_string_literal: true

module Legion
  module Extensions
    module Ollama
      module Runners
        # Fleet runner — handles inbound AMQP LLM request messages and dispatches
        # them to the appropriate Ollama::Client method based on request_type.
        #
        # Called by Actor::ModelWorker with use_runner? = false.
        module Fleet
          class << self
            # Primary entry point called by the subscription actor.
            #
            # @param model [String] Ollama model name, e.g. "nomic-embed-text"
            # @param request_type [String] "chat", "embed", or "generate"
            # @param reply_to [String, nil] routing key for the reply queue (RPC pattern)
            # @param correlation_id [String, nil] fleet correlation ID, echoed back in reply
            # @param message_context [Hash] tracing context — copied verbatim into the reply
            # @param payload [Hash] remaining message keys passed to the Ollama client
            def handle_request(model:, request_type: 'chat', reply_to: nil,
                               correlation_id: nil, message_context: {}, **payload)
              received_at = Time.now.utc

              if payload[:stream]
                publish_error(
                  reply_to:        reply_to,
                  correlation_id:  correlation_id,
                  message_context: message_context,
                  model:           model,
                  request_type:    request_type,
                  error:           {
                    code:      'unsupported_streaming',
                    message:   'Streaming over the fleet AMQP bus is not supported in v1',
                    retriable: false,
                    category:  'validation',
                    provider:  'ollama'
                  }
                )
                return { result: nil, status: 422, error: 'unsupported_streaming' }
              end

              result = dispatch(model: model, request_type: request_type, **payload)
              returned_at = Time.now.utc

              if reply_to
                publish_reply(
                  reply_to:        reply_to,
                  correlation_id:  correlation_id,
                  message_context: message_context,
                  model:           model,
                  request_type:    request_type,
                  result:          result,
                  received_at:     received_at,
                  returned_at:     returned_at
                )
              end

              result
            end

            # Dispatch to the correct Ollama client method by request_type.
            #
            # @return [Hash] { result: body, status: code } or { result: nil, status: 500, error: msg }
            def dispatch(model:, request_type:, **payload)
              host   = ollama_host
              ollama = Legion::Extensions::Ollama::Client.new(host: host)

              case request_type.to_s
              when 'embed'
                input = payload[:input] || payload[:text]
                ollama.embed(model: model, input: input,
                             **payload.slice(:truncate, :options, :keep_alive, :dimensions))
              when 'generate'
                ollama.generate(model: model, prompt: payload[:prompt],
                                **payload.slice(:images, :format, :options, :system, :keep_alive))
              else
                ollama.chat(model: model, messages: payload[:messages],
                            **payload.slice(:tools, :format, :options, :keep_alive, :think))
              end
            rescue StandardError => e
              { result: nil, usage: {}, status: 500, error: e.message }
            end

            # Publish a successful fleet response to the caller's reply_to queue.
            # Errors are swallowed so the AMQP ack path is never blocked by a broken reply.
            def publish_reply(reply_to:, correlation_id:, message_context:, model:,
                              request_type:, result:, received_at:, returned_at:)
              return unless defined?(Legion::Transport)

              body   = result[:result] || {}
              usage  = result[:usage] || {}
              status = result[:status] || 200
              latency_ms = ((returned_at - received_at) * 1000).round

              Transport::Messages::LlmResponse.new(
                reply_to:             reply_to,
                fleet_correlation_id: correlation_id,
                message_context:      message_context,
                provider:             'ollama',
                model:                model,
                request_type:         request_type,
                app_id:               'lex-ollama',
                **build_response_body(
                  request_type: request_type,
                  body:         body,
                  usage:        usage,
                  status:       status,
                  model:        model,
                  latency_ms:   latency_ms,
                  received_at:  received_at,
                  returned_at:  returned_at
                )
              ).publish
            rescue StandardError
              nil
            end

            # Publish a fleet error to the caller's reply_to queue.
            # Errors are swallowed so the AMQP ack path is never blocked.
            def publish_error(reply_to:, correlation_id:, message_context:, model:,
                              request_type:, error:)
              return unless reply_to
              return unless defined?(Legion::Transport)

              Legion::LLM::Fleet::Error.new(
                reply_to:             reply_to,
                fleet_correlation_id: correlation_id,
                message_context:      message_context,
                provider:             'ollama',
                model:                model,
                request_type:         request_type,
                app_id:               'lex-ollama',
                error:                error,
                worker_node:          node_identity
              ).publish
            rescue StandardError
              nil
            end

            private

            # Build the JSON body for a successful fleet response.
            def build_response_body(request_type:, body:, usage:, status:, model:,
                                    latency_ms:, received_at:, returned_at:)
              base = {
                routing:    {
                  provider:   'ollama',
                  model:      model,
                  tier:       'fleet',
                  strategy:   'fleet_dispatch',
                  latency_ms: latency_ms
                },
                tokens:     {
                  input:  usage[:input_tokens]  || 0,
                  output: usage[:output_tokens] || 0,
                  total:  (usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)
                },
                stop:       { reason: body.is_a?(Hash) ? body['done_reason'] : nil },
                cost:       { estimated_usd: 0.0, provider: 'ollama', model: model },
                timestamps: {
                  received:       received_at.iso8601(3),
                  provider_start: received_at.iso8601(3),
                  provider_end:   returned_at.iso8601(3),
                  returned:       returned_at.iso8601(3)
                },
                audit:      {
                  'fleet:execute' => {
                    outcome:     status == 200 ? 'success' : 'error',
                    duration_ms: latency_ms,
                    timestamp:   returned_at.iso8601(3)
                  }
                },
                stream:     false
              }

              case request_type.to_s
              when 'embed'
                base.merge(
                  embeddings: body.is_a?(Hash) ? body['embeddings'] : body
                )
              when 'generate'
                base.merge(
                  message: { role: 'assistant', content: body.is_a?(Hash) ? body['response'] : body }
                )
              else
                content = body.is_a?(Hash) ? body.dig('message', 'content') : body
                base.merge(
                  message: { role: 'assistant', content: content }
                )
              end
            end

            # Resolve the Ollama host from settings, falling back to the default.
            def ollama_host
              return Helpers::Client::DEFAULT_HOST unless defined?(Legion::Settings)

              Legion::Settings.dig(:ollama, :host) || Helpers::Client::DEFAULT_HOST
            end

            # Resolve the local node identity for worker_node in error messages.
            def node_identity
              return 'unknown' unless defined?(Legion::Settings)

              Legion::Settings.dig(:node, :canonical_name) || 'unknown'
            end
          end
        end
      end
    end
  end
end
