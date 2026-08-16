# frozen_string_literal: true

# Mirrors upstream tests/isolate.spec.ts, plus intercept (no upstream standalone spec;
# semantics taken from Service[resolveConfig] and fiber.ts inject-config handling).
RSpec.describe 'isolation and intercept' do
  let(:ctx) { Cordis::Context.new }
  let(:log) { [] }

  let(:consumer) do
    { name: 'consumer', inject: [:foo], apply: lambda { |_c, _config|
      log << :load
      -> { log << :unload }
    } }
  end

  describe 'ctx.isolate' do
    it 'keeps provides in separate realms per isolated context' do
      with_reactor do
        ctx.plugin(consumer)
        ctx1 = ctx.isolate(:foo)
        ctx1.plugin(consumer)
        ctx2 = ctx.isolate(:foo)
        ctx2.plugin(consumer)
        tick

        # provide in the default realm: only the root consumer loads
        dispose0 = ctx.provide(:foo, { bar: 100 })
        expect(ctx.get(:foo)).to eq({ bar: 100 })
        expect(ctx1.get(:foo)).to be_nil
        expect(ctx2.get(:foo)).to be_nil
        tick
        expect(log).to eq([:load])

        # provide in ctx1's realm: only ctx1's consumer loads
        ctx1.provide(:foo, { bar: 200 })
        expect(ctx.get(:foo)).to eq({ bar: 100 })
        expect(ctx1.get(:foo)).to eq({ bar: 200 })
        expect(ctx2.get(:foo)).to be_nil
        tick
        expect(log).to eq(%i[load load])

        # disposing the default-realm provide only unloads the root consumer
        dispose0.call
        expect(ctx.get(:foo)).to be_nil
        expect(ctx1.get(:foo)).to eq({ bar: 200 })
        tick
        expect(log).to eq(%i[load load unload])

        ctx2.provide(:foo, { bar: 300 })
        expect(ctx2.get(:foo)).to eq({ bar: 300 })
        tick
        expect(log).to eq(%i[load load unload load])
      end
    end

    it 'shares one realm between isolates created with the same label' do
      with_reactor do
        label = Object.new
        ctx1 = ctx.isolate(:foo, label)
        ctx1.plugin(consumer)
        ctx2 = ctx.isolate(:foo, label)
        ctx2.plugin(consumer)
        tick
        expect(log).to eq([])

        ctx.provide(:foo, { bar: 100 })
        tick
        expect(log).to eq([]) # default realm is invisible to both

        dispose12 = ctx1.provide(:foo, { bar: 200 })
        expect(ctx1.get(:foo)).to eq({ bar: 200 })
        expect(ctx2.get(:foo)).to eq({ bar: 200 })
        tick
        expect(log).to eq(%i[load load])

        dispose12.call
        expect(ctx1.get(:foo)).to be_nil
        expect(ctx2.get(:foo)).to be_nil
        tick
        expect(log).to eq(%i[load load unload unload])
      end
    end

    it 'allows the same name to be provided once per realm (duplicate within a realm still raises)' do
      with_reactor do
        ctx.provide(:foo, 1)
        ctx.isolate(:foo).provide(:foo, 2) # different realm: fine
        expect { ctx.provide(:foo, 3) }.to raise_error(Cordis::ServiceError, /already been registered/)
      end
    end

    it 'stops the service walk at an isolation boundary' do
      with_reactor do
        ctx.provide(:foo, :root_value)
        # plugin registered through an isolated ctx must not see the default-realm :foo
        fiber = ctx.isolate(:foo).plugin(lambda { |c, _config|
          log << begin
            c.foo
          rescue Cordis::ServiceError => e
            e.message
          end
        })
        fiber.await
        expect(log).to eq(['cannot get property "foo" without inject'])
      end
    end
  end

  describe 'ctx.intercept' do
    it 'resolves config with inner intercepts overriding outer ones over a base' do
      ctx2 = ctx.intercept(:foo, { a: 1, b: 1 }).intercept(:foo, { b: 2 })
      expect(ctx2.resolve_config(:foo, { a: 0, c: 3 })).to eq({ a: 1, b: 2, c: 3 })
      expect(ctx.resolve_config(:foo, { a: 0 })).to eq({ a: 0 }) # original ctx untouched
    end

    it 'turns a Hash inject config into an intercept on the plugin ctx' do
      with_reactor do
        ctx.provide(:foo, :service)
        plugin = { name: 'web', inject: { foo: { level: 5 } }, apply: lambda { |c, _config|
          log << c.resolve_config(:foo, { level: 1, extra: true })
        } }
        ctx.plugin(plugin).await
        expect(log).to eq([{ level: 5, extra: true }])
      end
    end
  end
end
