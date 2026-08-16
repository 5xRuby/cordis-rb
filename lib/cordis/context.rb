# frozen_string_literal: true

module Cordis
  # 薄殼:root bootstrap、service 存取(coeffect 的 Σ)、plugin/event 入口的委派。
  # 破壞性變更(round 2):extend 對齊上游語意 —— 產生「同 root、不同 fiber」的 ctx 視角,
  # 不再是新的 disposal scope;新 scope 一律來自 ctx.plugin。
  class Context
    Impl = Struct.new(:name, :fiber, :value)

    attr_reader :root, :registry, :events, :fiber, :services

    def initialize
      @root = self
      @services = {} # name => Impl(無 isolate,直接以 name 為 key)
      @fiber = Fiber.new(self) # root fiber:恆 active,dispose = restart
      @registry = Registry.new(self)
      @events = Events.new(self)
    end

    # 內部用:綁定另一個 fiber 的 ctx 視角(共用 root/registry/events/services)。
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

    # 提供 service 本身就是一個 revertible effect。
    # teardown 順序保證:先從 store 移除 → notify → 等所有依賴者卸載完 →
    # 最後才刪 provider 自見的 entry(依賴者的 disposer 在 teardown 中仍可取用該 service)。
    def provide(name, value = nil)
      name = name.to_sym
      owner = @fiber
      @fiber.effect("ctx.provide(#{name.inspect})") do
        raise ServiceError, "service #{name.inspect} has already been registered" if @root.services.key?(name)

        impl = Impl.new(name, owner, value)
        @root.services[name] = impl
        owner.store[name] = impl # provider 對自己立即可見
        owner.provided << name
        @root.notify([name]) if owner.state == :active
        lambda do
          @root.services.delete(name)
          dependents = @root.notify([name])
          dependents.each do |dep|
            dep.await
          rescue StandardError
            nil # allSettled 語意:個別依賴者卸載失敗不阻斷
          end
          owner.store&.delete(name)
          owner.provided.delete(name)
        end
      end
    end

    # strict:provider fiber 必須 ACTIVE 才可見(async 載入中的 service 對依賴者不可見)。
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

    # 依賴圖更新(全同步):線性掃描所有 fiber,重查滿足狀態並重算 epoch。
    # 回傳被觸及的 fiber 清單(provide teardown 用它等依賴者卸載)。
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

    # service 存取:沿 fiber parent chain 找快照(錯誤訊息對齊上游)。
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
