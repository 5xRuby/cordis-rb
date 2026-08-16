# frozen_string_literal: true

RSpec.describe 'ctx.plugin' do
  let(:ctx) { Cordis::Context.new }
  let(:log) { [] }

  it 'defers apply by one tick after plugin() returns' do
    with_reactor do
      ctx.plugin(->(_c, _config) { log << :apply })
      expect(log).to eq([])
      tick
      expect(log).to eq([:apply])
    end
  end

  it 'passes ctx and config to the callback' do
    with_reactor do
      fiber = ctx.plugin(->(_c, config) { log << config }, { port: 80 })
      fiber.await
      expect(log).to eq([{ port: 80 }])
      expect(fiber.state).to eq(:active)
    end
  end

  it 'accepts hash plugins with apply/name' do
    with_reactor do
      fiber = ctx.plugin({ name: 'demo', apply: ->(_c, _config) { log << :apply } })
      fiber.await
      expect(fiber.name).to eq('demo')
      expect(log).to eq([:apply])
    end
  end

  it 'raises ArgumentError for invalid plugins' do
    expect { ctx.plugin(42) }.to raise_error(ArgumentError, /invalid plugin/)
    expect { ctx.plugin({ apply: :nope }) }.to raise_error(ArgumentError, /callable/)
  end

  it 'collects a callable plugin return value as a disposer' do
    with_reactor do
      fiber = ctx.plugin(->(_c, _config) { -> { log << :cleanup } })
      fiber.await
      fiber.dispose
      expect(log).to eq([:cleanup])
    end
  end

  it 'raises InactiveEffectError for plugin/effect/on inside a disposer' do
    with_reactor do
      errors = []
      fiber = ctx.plugin(lambda { |c, _config|
        c.effect do
          lambda do
            [
              -> { c.plugin(->(*) {}) },
              -> { c.effect { -> {} } },
              -> { c.on('custom') { nil } }
            ].each do |attempt|
              attempt.call
            rescue Cordis::InactiveEffectError => e
              errors << e
            end
          end
        end
      })
      fiber.await
      fiber.dispose
      expect(errors.size).to eq(3)
      expect(errors).to all(have_attributes(message: /inactive context/))
    end
  end

  it 'disposes nested plugins with the whole subtree' do
    with_reactor do
      inner = ->(c, _config) { c.on('custom') { log << :inner } }
      outer = lambda { |c, _config|
        c.on('custom') { log << :outer1 }
        c.plugin(inner)
        c.on('custom') { log << :outer2 }
      }
      fiber = ctx.plugin(outer)
      fiber.await
      tick # inner 的載入再延一個 tick
      expect(ctx.events.hooks['custom'].size).to eq(3)
      expect(ctx.registry.size).to eq(2)

      fiber.dispose
      expect(ctx.events.hooks['custom'].size).to eq(0)
      expect(ctx.registry.size).to eq(0)
      expect { fiber.dispose }.not_to(change { log.size }) # 重複 dispose no-op
    end
  end

  it 'does not leak hooks across a load/unload cycle' do
    with_reactor do
      plugin = lambda { |c, _config|
        c.on('custom') { nil }
        c.plugin(->(c2, _cfg) { c2.on('custom') { nil } })
      }
      2.times do
        fiber = ctx.plugin(plugin)
        fiber.await
        tick
        fiber.dispose
      end
      expect(ctx.events.hooks.values.map(&:size)).to all(eq(0))
      expect(ctx.registry.size).to eq(0)
    end
  end

  it 'restarts the root fiber on dispose instead of destroying it' do
    with_reactor do
      ctx.effect do
        log << :apply
        -> { log << :revert }
      end
      ctx.fiber.dispose
      expect(log).to eq(%i[apply revert])
      expect(ctx.fiber.uid).to eq(0)
      expect(ctx.fiber.state).to eq(:active)
      ctx.effect { -> {} } # root 仍可繼續使用
    end
  end
end
