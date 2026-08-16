# frozen_string_literal: true

require 'async'

module Cordis
  # Event system (upstream 4.0's EventsService): registering a listener is itself a
  # fiber effect, so listeners are removed automatically when the fiber unloads.
  # emit/bail/waterfall are synchronous; parallel requires a reactor.
  class Events
    Hook = Struct.new(:ctx, :callback)

    attr_reader :hooks

    def initialize(ctx)
      @ctx = ctx
      @hooks = Hash.new { |hash, key| hash[key] = [] }
    end

    def register(ctx, name, prepend: false, &callback)
      list = @hooks[name]
      hook = Hook.new(ctx, callback)
      ctx.fiber.effect("ctx.on(#{name.inspect})") do
        prepend ? list.unshift(hook) : list.push(hook)
        -> { list.reject! { |h| h.equal?(hook) } }
      end
    end

    def once(ctx, name, prepend: false, &callback)
      dispose = register(ctx, name, prepend: prepend) do |*args|
        dispose.call
        callback.call(*args)
      end
    end

    # Synchronous fan-out; return values ignored; listener exceptions propagate (matches upstream).
    def emit(name, *)
      @hooks[name].dup.each { |hook| hook.callback.call(*) }
      nil
    end

    # Sequential calls; returns the first non-nil/false result.
    # serial is the same semantics named for async listeners: Ruby async is blocking-style,
    # a listener just blocks, so the two share one implementation.
    def bail(name, *)
      @hooks[name].dup.each do |hook|
        result = hook.callback.call(*)
        return result if bailed?(result)
      end
      nil
    end
    alias serial bail

    # Middleware chain: each listener receives an extra next (callable); not calling
    # next stops the chain; the fallback block runs only when every listener passed through.
    def waterfall(name, *, &fallback)
      chain = @hooks[name].dup
      index = -1
      step = nil
      step = lambda do |*current|
        index += 1
        if index < chain.size
          chain[index].callback.call(*current, step)
        elsif fallback
          fallback.call(*current)
        end
      end
      step.call(*)
    end

    # Call all listeners concurrently without short-circuiting: exceptions are collected
    # into an AggregateError after everything ran (requires Sync/Async).
    def parallel(name, *)
      parent = Async::Task.current
      tasks = @hooks[name].dup.map do |hook|
        parent.async { hook.callback.call(*) }
      end
      errors = []
      tasks.each do |task|
        task.wait
      rescue StandardError => e
        errors << e
      end
      raise AggregateError, errors unless errors.empty?

      nil
    end

    private

    def bailed?(result) = !result.nil? && result != false
  end
end
