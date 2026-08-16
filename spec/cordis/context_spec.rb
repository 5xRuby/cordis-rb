# frozen_string_literal: true

RSpec.describe Cordis::Context do
  let(:ctx) { described_class.new }
  let(:log) { [] }

  def track(name)
    ctx.effect do
      log << [:apply, name]
      -> { log << [:revert, name] }
    end
  end

  describe '#effect' do
    it 'applies the effect immediately' do
      track(:a)
      expect(log).to eq([%i[apply a]])
    end

    it 'raises ArgumentError when the block returns a non-callable' do
      expect { ctx.effect { :not_callable } }.to raise_error(ArgumentError, /callable/)
    end

    it 'raises DisposedError on a disposed context' do
      ctx.dispose
      expect { track(:a) }.to raise_error(Cordis::DisposedError)
    end
  end

  describe '#dispose' do
    it 'calls inverses in LIFO order' do
      track(:a)
      track(:b)
      track(:c)
      ctx.dispose
      expect(log.last(3)).to eq([%i[revert c], %i[revert b], %i[revert a]])
    end

    it 'is idempotent — second dispose does not rerun inverses' do
      track(:a)
      ctx.dispose
      expect { ctx.dispose }.not_to(change { log.size })
      expect(ctx).to be_disposed
    end

    it 'keeps reverting remaining effects when one inverse raises' do
      track(:a)
      ctx.effect { -> { raise 'boom' } }
      track(:c)
      expect { ctx.dispose }.to output(/boom/).to_stderr
      expect(log.last(2)).to eq([%i[revert c], %i[revert a]])
    end
  end

  describe 'early disposer' do
    it 'reverts the single effect and removes it from the stack' do
      disposer = track(:a)
      track(:b)
      disposer.call
      expect(log.last).to eq(%i[revert a])
      ctx.dispose
      expect(log.count(%i[revert a])).to eq(1)
    end

    it 'is idempotent' do
      disposer = track(:a)
      disposer.call
      expect { disposer.call }.not_to(change { log.size })
    end

    it 'does not remove a duplicate registration of the same inverse' do
      inverse = -> { log << %i[revert dup] }
      disposer = ctx.effect { inverse }
      ctx.effect { inverse }
      disposer.call
      ctx.dispose
      expect(log.count(%i[revert dup])).to eq(2)
    end
  end

  describe '#extend' do
    it 'disposes child effects when the parent is disposed, in LIFO position' do
      track(:before)
      child = ctx.extend
      child.effect do
        log << %i[apply child]
        -> { log << %i[revert child] }
      end
      track(:after)
      ctx.dispose
      expect(log.last(3)).to eq([%i[revert after], %i[revert child], %i[revert before]])
      expect(child).to be_disposed
    end

    it 'does not re-dispose a child that was disposed on its own' do
      child = ctx.extend
      child.effect do
        -> { log << %i[revert child] }
      end
      child.dispose
      expect { ctx.dispose }.not_to(change { log.count(%i[revert child]) })
    end

    it 'raises DisposedError on a disposed context' do
      ctx.dispose
      expect { ctx.extend }.to raise_error(Cordis::DisposedError)
    end
  end
end
