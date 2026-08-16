# cordis-rb

[English](#english) | [繁體中文](#繁體中文) | [日本語](#日本語)

---

## English

> ⚠️ **Experimental** — a learning/research project, not production-ready. APIs change without notice.

cordis-rb is a Ruby reimplementation of the core mechanisms of [Cordis](https://github.com/cordiverse/cordis) (a TypeScript plugin/lifecycle meta-framework), based on the paper *"A Programming Paradigm for Spatiotemporal Composability"*. It is built on the [async](https://github.com/socketry/async) gem, using Fiber-based cooperative concurrency in place of the event loop that JavaScript gets for free.

### What's here so far

- **Context tree** — parent/child scopes via `ctx.extend`
- **Revertible effects** — `ctx.effect` applies a side effect and registers its inverse; `ctx.dispose` reverts the whole subtree in strict LIFO order (Theorem 16 of the paper: strict LIFO suffices to correctly revert non-commutative effects within a component)

```ruby
ctx = Cordis::Context.new

ctx.effect do
  server.listen(8080)
  -> { server.close }   # return the inverse
end

child = ctx.extend      # child scope
ctx.dispose             # reverts the whole tree, LIFO
```

### Roadmap

- [ ] Reactive coeffects — service injection with activating/deactivating notifications (this is where `async` comes in)
- [ ] Event system (`ctx.on`)
- [ ] Waterfall event chains, hot-reload reconciliation — maybe, later

### Development

```
bundle install && bundle exec rspec
```

---

## 繁體中文

> ⚠️ **實驗性專案** — 練習/研究用途,不求生產可用,API 隨時會變。

cordis-rb 用 Ruby 重新實作 [Cordis](https://github.com/cordiverse/cordis)(TypeScript 的 plugin/生命週期 meta-framework)的核心機制,理論基礎來自論文 *"A Programming Paradigm for Spatiotemporal Composability"*。以 [async](https://github.com/socketry/async) gem 為併發基底 —— JavaScript 有 event loop 免費提供協作式併發,Ruby 沒有對應物,這裡用 Fiber-based 的 async 補上這塊。

### 目前完成

- **Context tree** — `ctx.extend` 建立 parent/child scope
- **Revertible effect** — `ctx.effect` 套用副作用並登記 inverse;`ctx.dispose` 以嚴格 LIFO 順序撤除整棵子樹(論文 Theorem 16:單一 component 內嚴格 LIFO 即可正確復原 non-commutative 效果)

```ruby
ctx = Cordis::Context.new

ctx.effect do
  server.listen(8080)
  -> { server.close }   # 回傳 inverse
end

child = ctx.extend      # 子 scope
ctx.dispose             # LIFO 撤除整棵樹
```

### Roadmap

- [ ] Reactive coeffect — service injection 與 activating/deactivating 通知(`async` 從這裡開始登場)
- [ ] 事件系統(`ctx.on`)
- [ ] Waterfall 事件鏈、hot-reload reconciliation — 骨架穩了再說

### 開發

```
bundle install && bundle exec rspec
```

---

## 日本語

> ⚠️ **実験的プロジェクト** — 学習・研究目的であり、プロダクション利用は想定していません。API は予告なく変わります。

cordis-rb は、[Cordis](https://github.com/cordiverse/cordis)(TypeScript 製の plugin / ライフサイクル meta-framework)のコア機構を Ruby で再実装するプロジェクトです。理論的基盤は論文 *"A Programming Paradigm for Spatiotemporal Composability"* にあります。並行処理の基盤には [async](https://github.com/socketry/async) gem を採用 —— JavaScript ではイベントループが協調的並行性を無償で提供しますが、Ruby には相当物がないため、Fiber ベースの async でその役割を担います。

### 現状

- **Context tree** — `ctx.extend` による parent/child スコープ
- **Revertible effect** — `ctx.effect` が副作用を適用して inverse を登録し、`ctx.dispose` がサブツリー全体を厳密な LIFO 順で巻き戻す(論文の Theorem 16:単一 component 内では厳密な LIFO だけで non-commutative な効果を正しく復元できる)

```ruby
ctx = Cordis::Context.new

ctx.effect do
  server.listen(8080)
  -> { server.close }   # inverse を返す
end

child = ctx.extend      # 子スコープ
ctx.dispose             # ツリー全体を LIFO で巻き戻す
```

### Roadmap

- [ ] Reactive coeffect — service injection と activating/deactivating 通知(ここから `async` の出番)
- [ ] イベントシステム(`ctx.on`)
- [ ] Waterfall イベントチェーン、hot-reload reconciliation — 骨格が安定してから

### 開発

```
bundle install && bundle exec rspec
```
