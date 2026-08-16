# frozen_string_literal: true

RSpec.describe 'service access' do
  let(:ctx) { Cordis::Context.new }

  it 'lets the provider access its own service, and raises without inject otherwise' do
    ctx.provide(:foo, 1)
    expect(ctx.foo).to eq(1)
    expect { ctx.bar }.to raise_error(Cordis::ServiceError, /cannot get property "bar" without inject/)
  end

  it 'raises on duplicate provide' do
    ctx.provide(:foo, 1)
    expect { ctx.provide(:foo, 2) }.to raise_error(Cordis::ServiceError, /already been registered/)
  end

  it 'set updates the value only from the owning fiber' do
    with_reactor do
      ctx.provide(:foo, 1)
      ctx.set(:foo, 2)
      expect(ctx.foo).to eq(2)
      expect { ctx.set(:bar, 1) }.to raise_error(Cordis::ServiceError, /without provide/)

      message = nil
      fiber = ctx.plugin(lambda { |c, _config|
        begin
          c.set(:foo, 3)
        rescue Cordis::ServiceError => e
          message = e.message
        end
      })
      fiber.await
      expect(message).to match(/in multiple fibers/)
    end
  end

  it 'reaches services provided by an ancestor fiber without inject' do
    ctx.provide(:foo, 5) # provided by the root fiber
    with_reactor do
      value = nil
      fiber = ctx.plugin(->(c, _config) { value = c.foo })
      fiber.await
      expect(value).to eq(5)
    end
  end

  it 'does not reach sibling services without inject' do
    with_reactor do
      provider = ctx.plugin(->(c, _config) { c.provide(:foo, 1) })
      provider.await
      error = nil
      outsider = ctx.plugin(lambda { |c, _config|
        begin
          c.foo
        rescue Cordis::ServiceError => e
          error = e
        end
      })
      outsider.await
      expect(error.message).to match(/without inject/)
    end
  end

  it 'raises in inactive context when accessing an injected service after disposal' do
    with_reactor do
      provider = ctx.plugin(->(c, _config) { c.provide(:foo, 1) })
      provider.await
      captured_ctx = nil
      consumer = ctx.inject([:foo]) { |c, _config| captured_ctx = c }
      tick
      expect(captured_ctx.foo).to eq(1)
      consumer.dispose
      expect { captured_ctx.foo }
        .to raise_error(Cordis::ServiceError, /cannot get required service "foo" in inactive context/)
    end
  end

  it 'get returns nil for unknown services and the value for active ones' do
    expect(ctx.get(:nope)).to be_nil
    ctx.provide(:foo, :bar)
    expect(ctx.get(:foo)).to eq(:bar)
  end
end
