# frozen_string_literal: true

module Cordis
  # Plugin registry: keyed by the resolved callback — one Runtime per callback,
  # applying the same plugin N times = N fibers under one Runtime.
  class Registry
    Runtime = Struct.new(:name, :callback, :fibers)

    def initialize(ctx)
      @ctx = ctx
      @store = {}
      @counter = 0
    end

    def next_uid = (@counter += 1)
    def size = @store.size
    def runtimes = @store.values

    # Entry point for ctx.plugin. Plugin shapes: a callable, or { apply:, inject:, name: }.
    # Returns the fiber synchronously; the actual apply is deferred one tick
    # (must be called inside Sync/Async).
    def plugin(ctx, plugin, config = nil)
      callback, inject, name = resolve(plugin)
      ctx.fiber.assert_active
      runtime = @store[callback] ||= Runtime.new(name, callback, [])
      Fiber.new(ctx, config: config, inject: inject, runtime: runtime)
    end

    def remove(fiber)
      runtime = fiber.runtime
      runtime.fibers.reject! { |f| f.equal?(fiber) }
      @store.delete(runtime.callback) if runtime.fibers.empty?
    end

    private

    def resolve(plugin)
      case plugin
      when Hash
        apply = plugin[:apply]
        raise ArgumentError, "invalid plugin: apply must be callable, got #{apply.inspect}" \
          unless apply.respond_to?(:call)

        [apply, normalize_inject(plugin[:inject]), plugin[:name]]
      else
        raise ArgumentError, "invalid plugin: #{plugin.inspect}" unless plugin.respond_to?(:call)

        [plugin, {}, nil]
      end
    end

    def normalize_inject(inject)
      case inject
      when nil then {}
      when Array then inject.to_h { |dep| [dep.to_sym, true] }
      when Hash then inject.transform_keys(&:to_sym)
      else raise ArgumentError, "invalid inject: #{inject.inspect}"
      end
    end
  end
end
