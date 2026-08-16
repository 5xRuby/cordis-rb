# frozen_string_literal: true

require 'async'

module Cordis
  # 事件系統(上游 4.0 的 EventsService):listener 註冊本身就是 fiber effect,
  # fiber 卸載時 listener 自動撤除。emit/bail/waterfall 同步;parallel 需要 reactor。
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

    # 同步 fan-out,忽略回傳值,listener 的例外直接外拋(對齊上游)。
    def emit(name, *)
      @hooks[name].dup.each { |hook| hook.callback.call(*) }
      nil
    end

    # 循序呼叫,回傳第一個非 nil/false 的結果。
    # serial 是 async listener 用的同名語意:Ruby async 是 blocking-style,listener 直接 block 即可,
    # 所以兩者實作相同。
    def bail(name, *)
      @hooks[name].dup.each do |hook|
        result = hook.callback.call(*)
        return result if bailed?(result)
      end
      nil
    end
    alias serial bail

    # middleware 鏈:每個 listener 多收一個 next(callable);不呼叫 next 鏈就停,
    # 全部走完才呼叫 fallback block。
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

    # 併發呼叫所有 listener,不短路:全部跑完後彙總例外成 AggregateError(需在 Sync/Async 內)。
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
