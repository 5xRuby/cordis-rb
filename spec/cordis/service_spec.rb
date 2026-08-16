# frozen_string_literal: true

RSpec.describe 'service injection (reactive coeffect)' do
  let(:ctx) { Cordis::Context.new }
  let(:log) { [] }

  it 'loads the consumer when the service appears and tears it down when it disappears' do
    with_reactor do
      consumer = ctx.inject([:foo]) do |c, _config|
        log << [:load, c.foo]
        -> { log << [:unload] }
      end
      tick
      expect(log).to eq([]) # dependency unsatisfied -> pending
      expect(consumer.state).to eq(:pending)

      provider = ctx.plugin(->(c, _config) { c.provide(:foo, 42) })
      provider.await
      tick # the consumer's reload is deferred one more tick
      expect(log).to eq([[:load, 42]])
      expect(consumer.state).to eq(:active)

      provider.dispose
      expect(log).to eq([[:load, 42], [:unload]])
      expect(consumer.state).to eq(:pending)
    end
  end

  it 'pending inject: a service is invisible while its provider is still loading' do
    with_reactor do
      gate = Async::Queue.new
      provider = ctx.plugin(lambda { |c, _config|
        c.provide(:foo, :ready)
        log << :providing
        gate.pop # async init: provider stuck mid-load
        log << :provider_done
      })
      ctx.inject([:foo]) { |c, _config| log << [:consumer, c.foo] }
      tick
      expect(log).to eq([:providing])
      expect(ctx.get(:foo)).to be_nil # strict: invisible until the provider is ACTIVE

      gate.push(nil)
      provider.await
      tick
      expect(log).to eq([:providing, :provider_done, %i[consumer ready]])
      expect(ctx.get(:foo)).to eq(:ready)
    end
  end

  it 'diamond dependencies registered out of order each initialize exactly once' do
    with_reactor do
      bar = { name: 'bar', inject: %i[foo qux], apply: lambda { |c, _config|
        log << :bar
        c.provide(:bar, c.foo + c.qux)
      } }
      foo = { name: 'foo', inject: %i[qux], apply: lambda { |c, _config|
        log << :foo
        c.provide(:foo, c.qux + 1)
      } }
      qux = { name: 'qux', apply: lambda { |c, _config|
        log << :qux
        c.provide(:qux, 1)
      } }
      ctx.plugin(bar)
      ctx.plugin(foo)
      last = ctx.plugin(qux)
      last.await
      tick(4) # layer-by-layer activation
      expect(log).to eq(%i[qux foo bar])
      expect(ctx.get(:bar)).to eq(3)
    end
  end

  it 'dependent disposers can still read the service during provider teardown' do
    with_reactor do
      provider = ctx.plugin(->(c, _config) { c.provide(:foo, 7) })
      provider.await
      teardown_value = nil
      ctx.inject([:foo]) do |c, _config|
        -> { teardown_value = c.foo }
      end
      tick
      provider.dispose
      expect(teardown_value).to eq(7)
    end
  end

  it 'tears down dependents before the provider finishes unloading' do
    with_reactor do
      provider = ctx.plugin(lambda { |c, _config|
        c.effect { -> { log << :provider_pre_provide } } # registered before provide -> disposed last
        c.provide(:foo, 1)
      })
      provider.await
      ctx.inject([:foo]) do |_c, _config|
        -> { log << :consumer }
      end
      tick
      provider.dispose
      expect(log).to eq(%i[consumer provider_pre_provide])
    end
  end
end
