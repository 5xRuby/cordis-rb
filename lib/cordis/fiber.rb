# frozen_string_literal: true

require 'async'

module Cordis
  # Fiber (upstream 4.0's new name for EffectScope): the lifecycle unit of a plugin,
  # and also the collector of revertible effects (the paper's phi accumulator).
  # Note: the clash with Ruby core's ::Fiber is deliberate, to match upstream naming;
  # Cordis never uses core Fiber directly.
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
      @internal_store = {} # currently satisfied dependencies (name => Impl), continuously updated
      @store = nil         # snapshot taken while loading; nil means unloaded
      @current_epoch = INACTIVE
      @target_epoch = INACTIVE
      @inertia = nil       # in-flight load/unload transition task
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
      # a plugin is itself a revertible effect on the parent fiber (mirrors upstream fiber.ts:170)
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

    # Apply a side effect and collect its inverse. The block returns: nil (nothing),
    # a callable (single disposer), or an Array/Enumerator of callables (multi-step
    # disposers, reverted in reverse order — upstream's function* effects).
    # If setup raises midway, already-collected disposers are rolled back in reverse, then re-raised.
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

    # Wait for all in-flight transitions to finish (while, not if: transitions chain).
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
      await # wait for the unload first (refreshing right away would set the target back
      # to the original epoch and coalesce the unload intent away)
      refresh
      await
    end

    def update(config)
      @config = config
      restart
    end

    # -- coeffect machinery (dependency-graph updates are fully synchronous;
    #    only load/unload execution is async) --

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
        # collect incrementally (never force the whole enumeration first): if it raises
        # midway, only disposers yielded so far can be rolled back
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
      return if @inertia # transition in flight: just record the intent; re-checked on completion

      start_transition
    end

    # Inertia lock: at most one transition task per fiber at a time; on completion the
    # target epoch is re-checked and, if it changed, the next transition is chained.
    def start_transition
      task = Async::Task.current # raises outside a reactor (plugin/provide require Sync/Async)
      set_state(@current_epoch == INACTIVE ? :loading : :unloading)
      @inertia = task.async do
        Async::Task.current.yield # defer by one tick (upstream's await Promise.resolve())
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
      @store = @internal_store.dup # snapshot: a loading plugin sees a frozen view of its deps
      set_state(:loading)
      begin
        result = @runtime.callback.call(@ctx, @config) unless root?
        # ponytail: a plugin return value only counts as a disposer when callable
        # (upstream _execute is stricter and raises TypeError)
        @disposables << Entry.new([result], 'plugin:return') if result.respond_to?(:call)
      rescue StandardError => e
        @error = e
        warn "Cordis: plugin #{name} failed to load: #{e.class}: #{e.message}"
      end
      @current_epoch = goal
    end

    def do_unload
      set_state(:unloading)
      # ponytail: strict LIFO sequential disposal, each rescued individually
      # (upstream starts in LIFO order but finishes concurrently)
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
      # crossing the ACTIVE boundary changes the visibility of services this fiber
      # provides -> notify dependents
      crossed = (old == :active) ^ (new_state == :active)
      @ctx.root.notify(@provided.dup) if crossed && !@provided.empty?
    end

    # Called by the parent's effect disposer (or manually via #dispose)
    def terminate
      set_epoch(INACTIVE)
      begin
        await
      rescue StandardError
        nil # disposing a FAILED fiber never raises (the error was already warned at load time)
      end
      @uid = nil
      set_state(:disposed)
      @ctx.root.registry.remove(self)
      @ctx.events.emit('internal/plugin', self)
    end
  end
end
