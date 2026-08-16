# frozen_string_literal: true

module Cordis
  # 論文對應:effect 為 Γ → Γ × (Γ → Γ),block 套用副作用後回傳 inverse;
  # @disposables 即 φ accumulator,dispose 時 LIFO 撤除(Theorem 16)。
  # 子 context 的 dispose 以一個 effect 掛在 parent 的 stack 上,整棵子樹自然落在 LIFO 順序裡。
  class Context
    def initialize
      @disposables = []
      @disposed = false
    end

    def disposed? = @disposed

    # block 立即執行(套用效果),必須回傳 callable 的 inverse。
    # 回傳 disposer:提早單獨撤除該 effect(冪等,並從 stack 除名)。
    def effect(&block)
      raise DisposedError, 'context already disposed' if @disposed

      inverse = block.call
      unless inverse.respond_to?(:call)
        raise ArgumentError, "effect block must return a callable inverse, got #{inverse.inspect}"
      end

      entry = [inverse]
      @disposables << entry
      lambda do
        # reject! 回傳 nil 代表 entry 已不在 stack(已撤除過或已被 dispose)→ no-op
        next unless @disposables.reject! { |e| e.equal?(entry) }

        inverse.call
      end
    end

    def extend
      raise DisposedError, 'context already disposed' if @disposed

      child = Context.new
      child_disposer = effect { -> { child.dispose } }
      child.effect { child_disposer } # child 單獨 dispose 時,從 parent stack 除名自己
      child
    end

    # LIFO 撤除;冪等。每個 inverse 各自 rescue,一個炸掉不影響其餘撤除。
    def dispose
      return if @disposed

      @disposed = true
      until @disposables.empty?
        entry = @disposables.pop
        begin
          entry.first.call
        rescue StandardError => e
          # ponytail: 只印 warning 不彙總,要嚴格語意時改收集後 raise 聚合錯誤
          warn "Cordis: inverse raised during dispose: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
