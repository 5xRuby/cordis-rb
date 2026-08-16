# frozen_string_literal: true

require 'async'

module Cordis
  # Fiber(上游 4.0 對 EffectScope 的新名字):plugin 的生命週期單位,
  # 同時是 revertible effect 的收集器(φ accumulator)。
  # 注意:刻意與 Ruby core 的 ::Fiber 撞名以對齊上游;Cordis 內部不直接使用 core Fiber。
  class Fiber
    INACTIVE = :__inactive__

    Entry = Struct.new(:disposers, :label)

    attr_reader :uid, :ctx, :runtime, :inject, :store, :config, :error, :provided, :parent_fiber, :state

    def initialize(parent_ctx, config: nil, inject: {}, runtime: nil)
      @config = config
      @inject = inject
      @runtime = runtime
      @disposables = []
      @provided = []
      @internal_store = {} # 目前被滿足的依賴(name => Impl),持續更新
      @store = nil         # 載入期間的快照;nil 代表 unloaded
      @current_epoch = INACTIVE
      @target_epoch = INACTIVE
      @inertia = nil       # 進行中的 load/unload transition task
      @error = nil
      @state = :pending

      if runtime.nil? # root fiber
        @uid = 0
        @ctx = parent_ctx
        @parent_fiber = nil
        @current_epoch = @target_epoch = ''
        @store = {}
        @state = :active
        return
      end

      @uid = parent_ctx.root.registry.next_uid
      @parent_fiber = parent_ctx.fiber
      @ctx = parent_ctx.extend(fiber: self)
      runtime.fibers << self
      @ctx.events.emit('internal/plugin', self)
      inject.each_key { |name| check_impl(name) }
      # plugin 本身就是掛在 parent fiber 上的一個 revertible effect(對齊 fiber.ts:170)
      @entry = parent_ctx.fiber.effect('ctx.plugin()') do
        refresh
        -> { terminate }
      end
    end

    def root? = @runtime.nil?
    def disposed? = @uid.nil?

    def name
      return 'root' if root?

      @runtime.name || 'plugin'
    end

    # 套用副作用並收集 inverse。block 回傳:nil(無事)、callable(單一 disposer)、
    # Array/Enumerator of callables(多步 disposer,反序撤除,對應上游 function* effect)。
    # setup 中途 raise 時,已收集的 disposer 反序回滾後重拋。
    def effect(label = nil, &block)
      assert_active
      disposers = collect_disposers(block, rollback: true)
      entry = Entry.new(disposers, label)
      @disposables << entry
      lambda do
        next unless @disposables.reject! { |e| e.equal?(entry) }

        entry.disposers.reverse_each(&:call)
      end
    end

    def assert_active
      return if @store && %i[loading active].include?(@state)

      raise InactiveEffectError, 'cannot create effect on inactive context'
    end

    # 等待進行中的 transition 全部結束(注意 while 不是 if:transition 會鏈)。
    def await
      while (task = @inertia)
        task.wait
      end
      raise @error if @error

      self
    end

    def dispose
      return restart if root?

      @entry.call
      nil
    end

    def restart
      set_epoch(INACTIVE)
      await # 先等卸載完(不能立刻 refresh:target 設回原 epoch 會把 unload 意圖合併掉)
      refresh
      await
    end

    def update(config)
      @config = config
      restart
    end

    # -- coeffect 機制(依賴圖更新全同步,只有 load/unload 執行是 async)--

    def check_impl(name)
      impl = @ctx.root.services[name]
      if impl && impl.fiber.state == :active
        @internal_store[name] = impl
      else
        @internal_store.delete(name)
      end
    end

    def refresh
      epoch = ''
      @inject.each_key do |name|
        impl = @internal_store[name]
        if impl.nil?
          epoch = INACTIVE
          break
        end
        epoch = "#{epoch}:#{impl.fiber.uid}"
      end
      set_epoch(epoch)
    end

    private

    def collect_disposers(block, rollback: false)
      disposers = []
      result = block.call
      case result
      when nil then nil
      when Array, Enumerator
        # 逐步收集(不可先整個展開):中途 raise 時已 yield 的 disposer 才能回滾
        result.each do |disposer|
          validate_disposer(disposer)
          disposers << disposer
        end
      else
        validate_disposer(result)
        disposers << result
      end
      disposers
    rescue StandardError
      disposers.reverse_each { |d| safe_call(d) } if rollback
      raise
    end

    def validate_disposer(disposer)
      return if disposer.respond_to?(:call)

      raise TypeError, "invalid effect: disposer must be callable, got #{disposer.inspect}"
    end

    def safe_call(disposer)
      disposer.call
    rescue StandardError => e
      warn "Cordis: error while disposing (#{name}): #{e.class}: #{e.message}"
    end

    def set_epoch(epoch)
      return if epoch == @target_epoch

      @target_epoch = epoch
      return if @inertia # transition 進行中:只記下意圖,完成時會重查

      start_transition
    end

    # inertia lock:每個 fiber 同時只有一個 transition task 在跑,
    # 完成時重查 target epoch,不符就鏈到下一個 transition。
    def start_transition
      task = Async::Task.current # reactor 外呼叫會 raise(plugin/provide 需在 Sync/Async 內)
      set_state(@current_epoch == INACTIVE ? :loading : :unloading)
      @inertia = task.async do
        Async::Task.current.yield # 一個 tick 的延後(對應上游 await Promise.resolve())
        loop do
          if @current_epoch == INACTIVE
            break if @target_epoch == INACTIVE

            do_load
          else
            break if @target_epoch == @current_epoch

            do_unload
          end
        end
        @inertia = nil
        set_state(resting_state)
      end
    end

    def do_load
      goal = @target_epoch
      @error = nil
      @store = @internal_store.dup # 快照:載入中的 plugin 看到凍結的依賴視圖
      set_state(:loading)
      begin
        result = @runtime.callback.call(@ctx, @config) unless root?
        # ponytail: plugin 回傳值只在 callable 時當 disposer(上游 _execute 較嚴格會 TypeError)
        @disposables << Entry.new([result], 'plugin:return') if result.respond_to?(:call)
      rescue StandardError => e
        @error = e
        warn "Cordis: plugin #{name} failed to load: #{e.class}: #{e.message}"
      end
      @current_epoch = goal
    end

    def do_unload
      set_state(:unloading)
      # ponytail: 嚴格 LIFO 循序撤除、逐個 rescue(上游是 LIFO 啟動 + 併發完成)
      until @disposables.empty?
        entry = @disposables.pop
        entry.disposers.reverse_each { |d| safe_call(d) }
      end
      @store = nil
      @error = nil
      @current_epoch = INACTIVE
    end

    def resting_state
      return :disposed if disposed?
      return :failed if @error

      @current_epoch == INACTIVE ? :pending : :active
    end

    def set_state(new_state)
      return if new_state == @state

      old = @state
      @state = new_state
      @ctx.events.emit('internal/status', self, old)
      # 跨越 ACTIVE 邊界時,本 fiber 提供的 service 可見性改變 → 通知依賴者
      crossed = (old == :active) ^ (new_state == :active)
      @ctx.root.notify(@provided.dup) if crossed && !@provided.empty?
    end

    # 由 parent 的 effect disposer 呼叫(或 #dispose 手動觸發)
    def terminate
      set_epoch(INACTIVE)
      begin
        await
      rescue StandardError
        nil # FAILED fiber 的 dispose 不外拋(錯誤已在載入時 warn 過)
      end
      @uid = nil
      set_state(:disposed)
      @ctx.root.registry.remove(self)
      @ctx.events.emit('internal/plugin', self)
    end
  end
end
