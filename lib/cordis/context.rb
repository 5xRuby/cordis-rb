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
      @services = {} # name => Impl (no isolate layer, keyed directly by name)
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
      owner = @fiber
      @fiber.effect("ctx.provide(#{name.inspect})") do
        raise ServiceError, "service #{name.inspect} has already been registered" if @root.services.key?(name)

        impl = Impl.new(name, owner, value)
        @root.services[name] = impl
        owner.store[name] = impl # immediately visible to the provider itself
        owner.provided << name
        @root.notify([name]) if owner.state == :active
        lambda do
          @root.services.delete(name)
          dependents = @root.notify([name])
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
      impl = @root.services[name.to_sym]
      return nil unless impl && impl.fiber.state == :active

      impl.value
    end

    def set(name, value)
      name = name.to_sym
      impl = @root.services[name]
      raise ServiceError, %(cannot set property "#{name}" without provide) unless impl
      raise ServiceError, %(cannot set property "#{name}" in multiple fibers) unless impl.fiber.equal?(@fiber)

      impl.value = value
    end

    # Dependency-graph update (fully synchronous): linear scan over all fibers,
    # re-checking satisfaction and recomputing epochs. Returns the touched fibers
    # (provide's teardown uses the list to wait for dependents).
    def notify(names)
      touched = []
      @registry.runtimes.each do |runtime|
        runtime.fibers.each do |fib|
          next unless names.any? { |n| fib.inject.key?(n) }

          names.each { |n| fib.check_impl(n) if fib.inject.key?(n) }
          fib.refresh
          touched << fib
        end
      end
      names.each { |n| @events.emit('internal/service', n) }
      touched
    end

    # Service access: walk the fiber parent chain looking at snapshots
    # (error messages match upstream).
    def method_missing(name, *args, &block)
      return super unless args.empty? && block.nil?

      resolve_service(name)
    end

    def respond_to_missing?(name, include_private = false)
      @root.services.key?(name) || super
    end

    private

    def resolve_service(name)
      fib = @fiber
      loop do
        if fib.store
          impl = fib.store[name]
          return impl.value if impl
        end
        raise ServiceError, %(cannot get required service "#{name}" in inactive context) if fib.inject.key?(name)
        raise ServiceError, %(cannot get property "#{name}" without inject) if fib.root?

        fib = fib.parent_fiber
      end
    end
  end
end
