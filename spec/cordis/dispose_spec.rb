# frozen_string_literal: true

RSpec.describe 'effect disposal' do
  let(:ctx) { Cordis::Context.new }
  let(:log) { [] }

  it 'applies the effect immediately and returns a disposer' do
    disposer = ctx.effect do
      log << :apply
      -> { log << :revert }
    end
    expect(log).to eq([:apply])
    disposer.call
    expect(log).to eq(%i[apply revert])
  end

  it 'raises TypeError when the block returns a non-callable' do
    expect { ctx.effect { :not_callable } }.to raise_error(TypeError, /callable/)
  end

  it 'reverts multi-step disposers of one effect in reverse order' do
    disposer = ctx.effect { [-> { log << 1 }, -> { log << 2 }, -> { log << 3 }] }
    disposer.call
    expect(log).to eq([3, 2, 1])
  end

  it 'collects disposers from an Enumerator' do
    disposer = ctx.effect do
      Enumerator.new do |y|
        y << -> { log << 1 }
        y << -> { log << 2 }
      end
    end
    disposer.call
    expect(log).to eq([2, 1])
  end

  it 'rolls back already-collected disposers when effect setup raises' do
    expect do
      ctx.effect do
        Enumerator.new do |y|
          y << -> { log << 1 }
          y << -> { log << 2 }
          raise 'setup boom'
        end
      end
    end.to raise_error(RuntimeError, 'setup boom')
    expect(log).to eq([2, 1])
  end

  it 'early disposer is idempotent' do
    disposer = ctx.effect { -> { log << :revert } }
    disposer.call
    expect { disposer.call }.not_to(change { log.size })
  end

  it 'does not remove a duplicate registration of the same inverse' do
    inverse = -> { log << :revert }
    first = ctx.effect { inverse }
    second = ctx.effect { inverse }
    first.call
    expect(log.size).to eq(1)
    second.call # 若 first 誤刪兩份,這裡會變 no-op
    expect(log.size).to eq(2)
  end

  it 'disposes effects in LIFO order when the fiber unloads' do
    with_reactor do
      fiber = ctx.plugin(lambda { |c, _config|
        %i[a b c].each do |name|
          c.effect do
            log << [:apply, name]
            -> { log << [:revert, name] }
          end
        end
      })
      fiber.await
      fiber.dispose
      expect(log.last(3)).to eq([%i[revert c], %i[revert b], %i[revert a]])
    end
  end

  it 'keeps reverting remaining effects when one disposer raises' do
    expect do
      with_reactor do
        fiber = ctx.plugin(lambda { |c, _config|
          c.effect { -> { log << :a } }
          c.effect { -> { raise 'boom' } }
          c.effect { -> { log << :c } }
        })
        fiber.await
        fiber.dispose
      end
    end.to output(/boom/).to_stderr
    expect(log).to eq(%i[c a])
  end

  it 'does not re-revert an effect disposed early when the fiber unloads' do
    with_reactor do
      early = nil
      fiber = ctx.plugin(lambda { |c, _config|
        early = c.effect { -> { log << :early } }
        c.effect { -> { log << :late } }
      })
      fiber.await
      early.call
      expect(log).to eq([:early])
      fiber.dispose
      expect(log).to eq(%i[early late])
    end
  end
end
