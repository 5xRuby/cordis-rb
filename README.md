# cordis-rb

[English](#english) | [繁體中文](#繁體中文) | [日本語](#日本語)

---

## English

> ⚠️ **Experimental** — a learning/research project, not production-ready. APIs change without notice.

cordis-rb is a Ruby reimplementation of the core mechanisms of [Cordis](https://github.com/cordiverse/cordis) (a TypeScript plugin/lifecycle meta-framework), based on the paper *"A Programming Paradigm for Spatiotemporal Composability"*. It is built on the [async](https://github.com/socketry/async) gem, using Fiber-based cooperative concurrency in place of the event loop that JavaScript gets for free.

### What's here so far

Aligned with upstream `packages/core` (4.0 naming: `Fiber`, formerly `EffectScope`):

- **Revertible effects** — `ctx.effect` applies a side effect and registers its inverse (single or multi-step); disposal is strict LIFO (Theorem 16)
- **Plugin system** — `ctx.plugin` applies a plugin *as a revertible effect* on the parent fiber, so the whole plugin tree is one nested effect tree; loading is deferred one tick, load/unload transitions are serialized per fiber (inertia lock)
- **Reactive coeffects** — `ctx.provide` / `ctx.inject`: consumers load when their dependencies are satisfied, reload when a provider is swapped, and are torn down *before* their provider finishes unloading
- **Events** — `ctx.on` / `once` / `emit` / `bail` / `waterfall` (sync) and `ctx.parallel` / `serial` (async); listeners are effects, removed automatically on fiber disposal
- **Isolation & intercept** — `ctx.isolate` puts a service name in its own realm (provides/injects no longer cross the boundary; share a realm by passing the same label); `ctx.intercept` / Hash inject configs carry per-caller config, resolved with `ctx.resolve_config`

```ruby
ctx = Cordis::Context.new

Sync do
  provider = ctx.plugin(lambda { |c, _config|
    db = Database.connect
    c.effect { -> { db.close } } # registered before provide → runs after all dependents are gone
    c.provide(:db, db)
  })

  ctx.inject([:db]) do |c, _config|
    c.on('request') { |req| c.db.query(req) } # loads only once :db is active
  end

  provider.await   # wait for the deferred load
  provider.dispose # dependents tear down first, then the provider, LIFO
end
```

### Roadmap

- [x] Revertible effects with LIFO disposal
- [x] Plugin/fiber lifecycle (epoch + inertia state machine, via `async`)
- [x] Reactive coeffects (`ctx.provide` / `ctx.inject`)
- [x] Event system (`ctx.on`, waterfall included)
- [x] Isolation & intercept (`ctx.isolate` / `ctx.intercept`)
- [ ] `Cordis::Service` base class
- [ ] Loader / hot-reload reconciliation — maybe, later

### Development

```
bundle install && bundle exec rspec
bundle exec ruby examples/demo.rb   # lifecycle / coeffect walkthrough
ruby examples/webapp.rb             # the same story with Sinatra + Falcon + SQLite
```

---

## 繁體中文

> ⚠️ **實驗性專案** — 練習/研究用途,不求生產可用,API 隨時會變。

cordis-rb 用 Ruby 重新實作 [Cordis](https://github.com/cordiverse/cordis)(TypeScript 的 plugin/生命週期 meta-framework)的核心機制,理論基礎來自論文 *"A Programming Paradigm for Spatiotemporal Composability"*。以 [async](https://github.com/socketry/async) gem 為併發基底 —— JavaScript 有 event loop 免費提供協作式併發,Ruby 沒有對應物,這裡用 Fiber-based 的 async 補上這塊。

### 目前完成

對接上游 `packages/core`(4.0 命名:`Fiber`,即原本的 `EffectScope`):

- **Revertible effect** — `ctx.effect` 套用副作用並登記 inverse(單步或多步);撤除嚴格 LIFO(Theorem 16)
- **Plugin 系統** — `ctx.plugin` 把 plugin *當成一個 revertible effect* 掛在 parent fiber 上,整棵 plugin tree 就是巢狀 effect tree;載入延後一個 tick,每個 fiber 的 load/unload 由 inertia lock 序列化
- **Reactive coeffect** — `ctx.provide` / `ctx.inject`:依賴滿足才載入、provider 被換掉就 reload、provider 卸載前依賴者先 teardown
- **事件系統** — `ctx.on` / `once` / `emit` / `bail` / `waterfall`(同步)與 `ctx.parallel` / `serial`(非同步);listener 就是 effect,fiber 卸載時自動移除
- **Isolation 與 intercept** — `ctx.isolate` 讓某個 service name 進入獨立 realm(provide/inject 不再跨界;傳同一個 label 可共用 realm);`ctx.intercept` 與 Hash 形式的 inject config 攜帶 per-caller 設定,用 `ctx.resolve_config` 解析

```ruby
ctx = Cordis::Context.new

Sync do
  provider = ctx.plugin(lambda { |c, _config|
    db = Database.connect
    c.effect { -> { db.close } } # 註冊在 provide 之前 → 所有依賴者卸載後才執行
    c.provide(:db, db)
  })

  ctx.inject([:db]) do |c, _config|
    c.on('request') { |req| c.db.query(req) } # :db active 之後才載入
  end

  provider.await   # 等延後的載入完成
  provider.dispose # 依賴者先卸載,再撤 provider,LIFO
end
```

### Roadmap

- [x] Revertible effect 與 LIFO 撤除
- [x] Plugin/fiber 生命週期(epoch + inertia 狀態機,基於 `async`)
- [x] Reactive coeffect(`ctx.provide` / `ctx.inject`)
- [x] 事件系統(`ctx.on`,含 waterfall)
- [x] Isolation 與 intercept(`ctx.isolate` / `ctx.intercept`)
- [ ] `Cordis::Service` base class
- [ ] Loader / hot-reload reconciliation — 骨架穩了再說

### 開發

```
bundle install && bundle exec rspec
bundle exec ruby examples/demo.rb   # 生命週期 / coeffect 導覽
ruby examples/webapp.rb             # 同一個故事,換成 Sinatra + Falcon + SQLite
```

---

## 日本語

> ⚠️ **実験的プロジェクト** — 学習・研究目的であり、プロダクション利用は想定していません。API は予告なく変わります。

cordis-rb は、[Cordis](https://github.com/cordiverse/cordis)(TypeScript 製の plugin / ライフサイクル meta-framework)のコア機構を Ruby で再実装するプロジェクトです。理論的基盤は論文 *"A Programming Paradigm for Spatiotemporal Composability"* にあります。並行処理の基盤には [async](https://github.com/socketry/async) gem を採用 —— JavaScript ではイベントループが協調的並行性を無償で提供しますが、Ruby には相当物がないため、Fiber ベースの async でその役割を担います。

### 現状

上流 `packages/core` に整合(4.0 命名:`Fiber`、旧 `EffectScope`):

- **Revertible effect** — `ctx.effect` が副作用を適用して inverse を登録(単段・多段);巻き戻しは厳密な LIFO(Theorem 16)
- **Plugin システム** — `ctx.plugin` は plugin を *revertible effect として* parent fiber に掛けるため、plugin ツリー全体が入れ子の effect ツリーになる;ロードは 1 tick 遅延、fiber ごとの load/unload は inertia lock で直列化
- **Reactive coeffect** — `ctx.provide` / `ctx.inject`:依存が満たされたらロード、provider が入れ替われば reload、provider のアンロード前に依存側が先に teardown
- **イベントシステム** — `ctx.on` / `once` / `emit` / `bail` / `waterfall`(同期)と `ctx.parallel` / `serial`(非同期);listener は effect であり、fiber の破棄時に自動で外れる
- **Isolation と intercept** — `ctx.isolate` は service name を独立した realm に隔離(provide/inject は境界を越えない;同じ label を渡せば realm を共有);`ctx.intercept` と Hash 形式の inject config は per-caller 設定を運び、`ctx.resolve_config` で解決

```ruby
ctx = Cordis::Context.new

Sync do
  provider = ctx.plugin(lambda { |c, _config|
    db = Database.connect
    c.effect { -> { db.close } } # provide より先に登録 → 依存側が全て消えた後に実行
    c.provide(:db, db)
  })

  ctx.inject([:db]) do |c, _config|
    c.on('request') { |req| c.db.query(req) } # :db が active になってからロード
  end

  provider.await   # 遅延ロードの完了を待つ
  provider.dispose # 依存側が先に teardown、その後 provider、LIFO
end
```

### Roadmap

- [x] Revertible effect と LIFO 巻き戻し
- [x] Plugin/fiber ライフサイクル(epoch + inertia ステートマシン、`async` ベース)
- [x] Reactive coeffect(`ctx.provide` / `ctx.inject`)
- [x] イベントシステム(`ctx.on`、waterfall 含む)
- [x] Isolation と intercept(`ctx.isolate` / `ctx.intercept`)
- [ ] `Cordis::Service` base class
- [ ] Loader / hot-reload reconciliation — 骨格が安定してから

### 開発

```
bundle install && bundle exec rspec
bundle exec ruby examples/demo.rb   # ライフサイクル / coeffect ウォークスルー
ruby examples/webapp.rb             # 同じストーリーを Sinatra + Falcon + SQLite で
```
