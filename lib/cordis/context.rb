# frozen_string_literal: true

module Cordis
  # Thin shell: root bootstrap, service access (the paper's coeffect context), and
  # delegation to the plugin/event entry points.
  # Breaking change (round 2): extend now matches upstream semantics — it creates a
  # "same root, different fiber" view of the ctx, not a new disposal scope; new scopes
  # always come from ctx.plugin.
  class Context
    Impl = Struct.new(:name, :fiber, :value)

    attr_reader :root, :registry, :events, :fiber, :services

    def initialize
      @root = self
      @services = {} # isolate key => Impl (default key is the name itself)
      @isolate = {}  # name => isolation label; absent = the shared default realm
      @intercept = {} # name => per-caller config (copy-on-write, chain pre-merged)
      @fiber = Fiber.new(self) # root fiber: always active, dispose = restart
      @registry = Registry.new(self)
      @events = Events.new(self)
    end

    # Internal: a ctx view bound to another fiber (sharing root/registry/events/services).
    def extend(fiber: @fiber)
      ctx = dup
      ctx.instance_variable_set(:@fiber, fiber)
      ctx
    end

    # A ctx view where service `name` lives in its own realm: provides/injects through
    # this view no longer see (or are seen by) the default realm. Pass the same label
    # to two isolate calls to share one realm between them.
    def isolate(name, label = nil)
      ctx = extend
      ctx.instance_variable_set(:@isolate, @isolate.merge(name.to_sym => label || Object.new))
      ctx
    end

    # A ctx view carrying per-caller config for service `name` (upstream ctx.intercept).
    # Nested intercepts merge, inner overriding outer (Hash configs only; anything else replaces).
    def intercept(name, config)
      name = name.to_sym
      old = @intercept[name]
      merged = old.is_a?(Hash) && config.is_a?(Hash) ? old.merge(config) : config
      ctx = extend
      ctx.instance_variable_set(:@intercept, @intercept.merge(name => merged))
      ctx
    end

    # Effective intercept config for `name` as seen from this ctx, merged over `base`
    # (upstream Service[resolveConfig], minus the Config schema merge).
    def resolve_config(name, base = nil)
      config = @intercept[name.to_sym]
      return base if config.nil?

      base.is_a?(Hash) && config.is_a?(Hash) ? base.merge(config) : config
    end

    # The store key for `name` in this ctx's realm.
    def isolate_key(name) = @isolate[name] || name

    # -- effect / plugin --

    def effect(label = nil, &) = @fiber.effect(label, &)
    def plugin(plugin, config = nil) = @root.registry.plugin(self, plugin, config)

    def inject(deps, &block)
      plugin({ inject: deps, apply: block, name: 'inject' })
    end

    # -- events --

    def on(name, prepend: false, &) = @root.events.register(self, name, prepend: prepend, &)
    def once(name, prepend: false, &) = @root.events.once(self, name, prepend: prepend, &)
    def emit(name, *) = @root.events.emit(name, *)
    def bail(name, *) = @root.events.bail(name, *)
    def serial(name, *) = @root.events.serial(name, *)
    def parallel(name, *) = @root.events.parallel(name, *)
    def waterfall(name, *, &) = @root.events.waterfall(name, *, &)

    # -- service(reactive coeffect)--

    # Providing a service is itself a revertible effect.
    # Teardown ordering guarantee: remove from the store -> notify -> wait for every
    # dependent to finish unloading -> only then delete the provider's self-visible entry
    # (so dependents' disposers can still reach the service during their own teardown).
    def provide(name, value = nil)
      name = name.to_sym
      key = isolate_key(name)
      owner = @fiber
      @fiber.effect("ctx.provide(#{name.inspect})") do
        raise ServiceError, "service #{name.inspect} has already been registered" if @root.services.key?(key)

        impl = Impl.new(name, owner, value)
        @root.services[key] = impl
        owner.store[name] = impl # immediately visible to the provider itself
        owner.provided[name] = key
        @root.notify({ name => key }) if owner.state == :active
        lambda do
          @root.services.delete(key)
          dependents = @root.notify({ name => key })
          dependents.each do |dep|
            dep.await
          rescue StandardError
            nil # allSettled semantics: one dependent failing to unload never blocks the rest
          end
          owner.store&.delete(name)
          owner.provided.delete(name)
        end
      end
    end

    # Strict: the provider fiber must be ACTIVE to be visible (a service whose provider
    # is still loading is invisible to dependents).
    def get(name)
      impl = @root.services[isolate_key(name.to_sym)]
      return nil unless impl && impl.fiber.state == :active

      impl.value
    end

    def set(name, value)
      name = name.to_sym
      impl = @root.services[isolate_key(name)]
      raise ServiceError, %(cannot set property "#{name}" without provide) unless impl
      raise ServiceError, %(cannot set property "#{name}" in multiple fibers) unless impl.fiber.equal?(@fiber)

      impl.value = value
    end

    # Dependency-graph update (fully synchronous): linear scan over all fibers,
    # re-checking satisfaction and recomputing epochs. Only fibers whose ctx resolves
    # the name to the same isolate key are touched. Takes { name => key } pairs and
    # returns the touched fibers (provide's teardown uses the list to wait for dependents).
    def notify(pairs)
      touched = []
      @registry.runtimes.each do |runtime|
        runtime.fibers.each do |fib|
          hits = pairs.select { |n, key| fib.inject.key?(n) && fib.ctx.isolate_key(n) == key }
          next if hits.empty?

          hits.each_key { |n| fib.check_impl(n) }
          fib.refresh
          touched << fib
        end
      end
      pairs.each_key { |n| @events.emit('internal/service', n) }
      touched
    end

    # Service access: walk the fiber parent chain looking at snapshots
    # (error messages match upstream).
    def method_missing(name, *args, &block)
      return super unless args.empty? && block.nil?

      resolve_service(name)
    end

    def respond_to_missing?(name, include_private = false)
      @root.services.key?(isolate_key(name)) || super
    end

    private

    def resolve_service(name)
      key = isolate_key(name)
      fib = @fiber
      loop do
        if fib.store
          impl = fib.store[name]
          # a service this fiber *provides* is only visible from the same realm
          # (stricter than upstream, whose walk is name-keyed at the terminal fiber)
          return impl.value if impl && (!fib.provided.key?(name) || fib.provided[name] == key)
        end
        raise ServiceError, %(cannot get required service "#{name}" in inactive context) if fib.inject.key?(name)
        # stop at root, or when walking up would cross an isolation boundary
        if fib.root? || fib.parent_ctx.isolate_key(name) != key
          raise ServiceError, %(cannot get property "#{name}" without inject)
        end

        fib = fib.parent_fiber
      end
    end
  end
end
