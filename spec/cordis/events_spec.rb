# frozen_string_literal: true

RSpec.describe 'events' do
  let(:ctx) { Cordis::Context.new }
  let(:log) { [] }

  it 'fires listeners in registration order and removes them via disposer' do
    ctx.on('custom') { log << :a }
    disposer = ctx.on('custom') { log << :b }
    ctx.emit('custom')
    expect(log).to eq(%i[a b])
    disposer.call
    ctx.emit('custom')
    expect(log).to eq(%i[a b a])
  end

  it 'passes emit arguments to listeners' do
    ctx.on('custom') { |x, y| log << [x, y] }
    ctx.emit('custom', 1, 2)
    expect(log).to eq([[1, 2]])
  end

  it 'prepend puts the listener first' do
    ctx.on('custom') { log << :a }
    ctx.on('custom', prepend: true) { log << :b }
    ctx.emit('custom')
    expect(log).to eq(%i[b a])
  end

  it 'once fires exactly once' do
    ctx.once('custom') { log << :once }
    ctx.emit('custom')
    ctx.emit('custom')
    expect(log).to eq([:once])
  end

  it 'emit propagates listener exceptions to the caller' do
    ctx.on('custom') { raise 'boom' }
    expect { ctx.emit('custom') }.to raise_error(RuntimeError, 'boom')
  end

  it 'bail returns the first non-nil/false result and stops' do
    ctx.on('custom') { nil }
    ctx.on('custom') { false }
    ctx.on('custom') do
      log << :hit
      42
    end
    ctx.on('custom') { log << :skipped }
    expect(ctx.bail('custom')).to eq(42)
    expect(log).to eq([:hit])
  end

  it 'waterfall threads values through next' do
    ctx.on('sum') { |value, nxt| nxt.call(value + 1) }
    ctx.on('sum') { |value, nxt| nxt.call(value * 2) }
    result = ctx.waterfall('sum', 3) { |value| value }
    expect(result).to eq(8)
  end

  it 'waterfall stops when a listener does not call next' do
    ctx.on('sum') { |_value, _nxt| :stopped }
    ctx.on('sum') do |_value, nxt|
      log << :unreachable
      nxt.call(0)
    end
    result = ctx.waterfall('sum', 3) { |_value| log << :fallback }
    expect(result).to eq(:stopped)
    expect(log).to eq([])
  end

  it 'parallel runs all listeners without short-circuiting and aggregates errors' do
    with_reactor do
      ctx.on('go') do
        log << :a
        raise 'e1'
      end
      ctx.on('go') { log << :b }
      ctx.on('go') do
        log << :c
        raise 'e2'
      end
      expect { ctx.parallel('go') }.to raise_error(Cordis::AggregateError) do |error|
        expect(error.errors.map(&:message)).to contain_exactly('e1', 'e2')
      end
      expect(log).to contain_exactly(:a, :b, :c)
    end
  end

  it 'serial calls blocking listeners sequentially and bails' do
    with_reactor do
      ctx.on('go') do
        Async::Task.current.yield
        log << :a
        nil
      end
      ctx.on('go') do
        log << :b
        :done
      end
      ctx.on('go') { log << :unreachable }
      expect(ctx.serial('go')).to eq(:done)
      expect(log).to eq(%i[a b])
    end
  end
end
