# frozen_string_literal: true

RSpec.describe Cordis::Fiber do
  let(:ctx) { Cordis::Context.new }
  let(:log) { [] }

  it 'chains an unload after the load when the dependency disappears mid-load' do
    with_reactor do
      gate = Async::Queue.new
      provider = ctx.plugin(->(c, _config) { c.provide(:foo, 1) })
      provider.await
      consumer = ctx.inject([:foo]) do |_c, _config|
        log << :load
        gate.pop
        -> { log << :unload }
      end
      tick
      expect(log).to eq([:load]) # consumer 卡在載入中

      disposal = Async { provider.dispose }
      tick
      expect(log).to eq([:load]) # provider 等 consumer 卸載,不會硬拔

      gate.push(nil)
      disposal.wait
      expect(log).to eq(%i[load unload])
      expect(consumer.state).to eq(:pending)
    end
  end

  it 'reloads with the new provider when it is swapped mid-load' do
    with_reactor do
      gate = Async::Queue.new
      provider_a = ctx.plugin(->(c, _config) { c.provide(:foo, 'old') })
      provider_a.await
      consumer = ctx.inject([:foo]) do |c, _config|
        log << [:load, c.foo]
        gate.pop
        -> { log << :unload }
      end
      tick
      expect(log).to eq([[:load, 'old']])

      disposal = Async { provider_a.dispose }
      provider_b = ctx.plugin(->(c, _config) { c.provide(:foo, 'new') })
      provider_b.await
      gate.push(nil) # 放行第一次載入
      gate.push(nil) # 放行換 provider 後的 reload
      consumer.await
      disposal.wait
      expect(log).to eq([[:load, 'old'], :unload, [:load, 'new']])
      expect(consumer.state).to eq(:active)
    end
  end

  it 'a raising plugin becomes failed while its sibling stays active, keeping pre-raise listeners' do
    expect do
      with_reactor do
        bad = ctx.plugin(lambda { |c, _config|
          c.on('custom') { log << :bad_listener }
          raise 'boom'
        })
        good = ctx.plugin(->(c, _config) { c.on('custom') { log << :good } })
        good.await
        expect { bad.await }.to raise_error(RuntimeError, 'boom')
        expect(bad.state).to eq(:failed)
        expect(good.state).to eq(:active)

        ctx.emit('custom')
        expect(log).to contain_exactly(:bad_listener, :good)

        bad.dispose # dispose 已 FAILED 的 fiber 不外拋,並清掉殘留 listener
        log.clear
        ctx.emit('custom')
        expect(log).to eq([:good])
      end
    end.to output(/boom/).to_stderr
  end

  it 'restart unloads and re-applies the plugin' do
    with_reactor do
      fiber = ctx.plugin(lambda { |c, _config|
        log << :apply
        c.effect { -> { log << :revert } }
        nil
      })
      fiber.await
      fiber.restart
      expect(log).to eq(%i[apply revert apply])
      expect(fiber.state).to eq(:active)
    end
  end

  it 'update swaps the config and restarts' do
    with_reactor do
      fiber = ctx.plugin(->(_c, config) { log << config }, 1)
      fiber.await
      fiber.update(2)
      expect(log).to eq([1, 2])
      expect(fiber.config).to eq(2)
    end
  end

  it 'emits internal/status for every state transition' do
    with_reactor do
      ctx.on('internal/status') { |fiber, old| log << [old, fiber.state] unless fiber.root? }
      fiber = ctx.plugin(->(*) {})
      fiber.await
      fiber.dispose
      expect(log).to eq([
                          %i[pending loading],
                          %i[loading active],
                          %i[active unloading],
                          %i[unloading pending],
                          %i[pending disposed]
                        ])
    end
  end
end
