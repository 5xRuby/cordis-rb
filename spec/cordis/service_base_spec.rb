# frozen_string_literal: true

# Mirrors upstream tests/service.spec.ts (minus the traceable-proxy cases,
# which need machinery cordis-rb deliberately skips).
RSpec.describe Cordis::Service do
  let(:ctx) { Cordis::Context.new }
  let(:log) { [] }

  it 'provides itself and runs #init as the load body' do
    events = log
    klass = Class.new(described_class) do
      provide :foo
      define_method(:init) { events << :init }
      def greet = 'hi'
    end

    with_reactor do
      fiber = ctx.plugin(klass)
      fiber.await
      expect(log).to eq([:init])
      expect(ctx.get(:foo)).to be_a(klass)
      expect(ctx.get(:foo).greet).to eq('hi')

      fiber.dispose
      expect(ctx.get(:foo)).to be_nil
    end
  end

  it 'requires a provide declaration' do
    klass = Class.new(described_class)
    with_reactor do
      fiber = ctx.plugin(klass)
      expect { fiber.await }.to raise_error(ArgumentError, /must declare `provide :name`/)
      expect(fiber.state).to eq(:failed)
    end
  end

  it 'blocks dependents while #init is still running (pending inject)' do
    events = log
    klass = Class.new(described_class) do
      provide :foo
      define_method(:init) do
        queue = Async::Queue.new
        ctx.on('custom-event') { queue.enqueue(true) }
        queue.dequeue
      end
    end

    with_reactor do
      ctx.inject([:foo]) { |_c, _config| events << :dependent }
      ctx.plugin(klass)
      tick(3)
      expect(log).to eq([]) # inject is blocked by #init

      ctx.emit('custom-event')
      tick(3)
      expect(log).to eq([:dependent])
    end
  end

  it 'loads chained service classes in dependency order regardless of plugin order' do
    events = log
    qux = Class.new(described_class) do
      provide :qux
      define_method(:init) { events << :qux }
    end
    foo = Class.new(described_class) do
      provide :foo
      inject :qux
      define_method(:init) { events << :foo }
    end
    bar = Class.new(described_class) do
      provide :bar
      inject :foo, :qux
      define_method(:init) { events << :bar }
    end

    with_reactor do
      ctx.plugin(foo)
      ctx.plugin(bar)
      ctx.plugin(qux)
      tick(10)
      expect(log).to eq(%i[qux foo bar])
    end
  end

  it 'accepts a Hash inject config, readable via resolve_config' do
    events = log
    klass = Class.new(described_class) do
      provide :consumer
      inject foo: { level: 5 }
      define_method(:init) { events << ctx.resolve_config(:foo, { level: 1, extra: true }) }
    end

    with_reactor do
      ctx.provide(:foo, :service)
      ctx.plugin(klass).await
      expect(log).to eq([{ level: 5, extra: true }])
    end
  end
end
