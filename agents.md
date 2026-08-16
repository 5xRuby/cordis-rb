# cordis-rb — agent notes

實驗性練習專案:用 Ruby 重實作 Cordis(TS plugin/生命週期 meta-framework)的核心機制。不求生產可用,型別安全不是考量重點。優先順序是「機制正確」而不是 API 表面覆蓋率。

上游 repo 本機位置:`/Users/ryudo/ghq/github.com/cordiverse/cordis`(對接目標是 `packages/core`,4.0.0-rc.8)。注意 4.0 改名:`EffectScope` → `Fiber`、`Lifecycle` → `EventsService`。

## 正式定義查詢

理論來自論文 *"A Programming Paradigm for Spatiotemporal Composability"*。不確定正式定義時,查 NotebookLM(內有 paper.pdf、cordis GitHub、deepseek-harness GitHub),不要憑印象猜:

```
notebooklm ask "..." --notebook b4683395-8795-47c8-9d7a-76f058954f06
```

## 論文模型 → 程式碼對應

- **Revertible effect**:effect 為 Γ → Γ × (Γ → Γ)。`Fiber#effect` 的 block 立即套用副作用、回傳 inverse(callable / callable 陣列 / Enumerator);`@disposables` stack 就是 φ accumulator,unload 嚴格 LIFO 撤除。
- **Theorem 16**:單一 component 內嚴格 LIFO 即可正確復原 non-commutative 效果。關鍵區分是 commutative vs non-commutative,不是「新增 vs 修改」。
- **Reactive coeffect**(已實作):`Fiber#inject`(宣告)+ `@internal_store`(目前被滿足的 provider)+ epoch 字串指紋(各 provider fiber uid;缺一個 → INACTIVE)。`Context#notify` 線性掃描 → `check_impl` → `refresh` → `set_epoch`。provider 換掉 → epoch 變 → 強制 reload。provider 卸載時,provide 的 disposer 先 notify、等所有依賴者卸載完,才刪 provider 自見的 entry —— 依賴者 teardown 順序由機制保證。
- **Plugin 即 effect**:`ctx.plugin` 把 plugin 的 dispose 當成一個 effect 掛在 parent fiber 上(上游 fiber.ts:170),整棵 plugin tree 就是巢狀 effect tree,沒有獨立的 teardown 路徑。

## 已定案的設計決策

- **API 命名仿 Cordis**(使用者確認):`ctx.effect` / `ctx.plugin` / `ctx.provide` / `ctx.inject` / `ctx.on`。`Cordis::Fiber` 刻意與 Ruby core `::Fiber` 撞名以對齊上游 4.0(Cordis 內部不直接用 core Fiber)。`Context#extend` 刻意遮蔽 `Object#extend`。
- **round 2 破壞性變更**:`ctx.extend` 對齊上游語意 = 「同 root、不同 fiber」的 ctx 視角,不再是新 disposal scope;新 scope 一律來自 `ctx.plugin`。round 1 的 `DisposedError` 移除,改 `InactiveEffectError` / `ServiceError`(訊息對齊上游)。
- **併發用 async gem(Fiber-based)**,不用 Thread+Mutex。Promise 語意在 Ruby 對應為「task 內直接 block」:需要 reactor 的 API(`plugin` / `dispose` / `await` / `parallel`)必須在 `Sync`/`Async` 內呼叫,reactor 外會 raise "No async task available!"。
- **載入延後一個 tick**(對應上游 `await Promise.resolve()`):async 的 child task 是 eager,所以 transition task 開頭 `Async::Task.current.yield`。
- **inertia lock**:每個 fiber 一個 transition task,loop 到 current epoch == target epoch 為止;transition 中 target 變更只記意圖。`restart` 必須先 `await` 卸載完再 `refresh`,否則 target 設回原 epoch 會把 unload 意圖合併掉(已踩過)。
- **與上游的刻意差異**(`# ponytail:` 註記):unload 是嚴格 LIFO「循序」撤除(上游是 LIFO 啟動 + 併發完成);plugin 回傳值只在 callable 時收為 disposer(上游 `_execute` 會對非法值 TypeError)。
- **isolate/intercept(round 3)**:isolate key 預設就是 name 本身(不學上游 `root[isolate][name] ??= Symbol` 的 lazy 建 key),isolated ctx 才在自己的 `@isolate` map 放 token(`Object.new` 或使用者傳的 label);map 是 copy-on-write merge,不用 prototype chain。service store 改以 key 為鍵、`Fiber#provided` 改 `{name => key}`、notify 收 `{name => key}` pairs 並過濾 `fib.ctx.isolate_key(n) == key`。intercept 同樣 copy-on-write,鏈在 `ctx.intercept` 時就地 merge 攤平(上游是 resolveConfig 走 prototype chain 收集再 assign),讀取入口是 `ctx.resolve_config(name, base)`;Hash 形式的 inject config 會轉成 plugin ctx 上的 intercept(對齊 fiber.ts:139)。**比上游嚴格的一處**:service walk 在終點 fiber 對 provided 服務檢查 realm key(上游 name-keyed store 會讓 isolated plugin 走到 root 時漏看到 default realm 的 service)。
- async 模式參考 `/Users/ryudo/RubyPrjs/lens-ruby-async`:完成訊號用 `Async::Queue` 不用 `Async::Condition`(signal 先於 wait 會遺失)、spec 用 `task.with_timeout` 包可能吊死的流程(spec_helper 的 `with_reactor`)、teardown 逐步各自 rescue。

## 範圍紀律

已完成:effect protocol、Fiber 狀態機(pending/loading/active/failed/disposed/unloading)、`ctx.plugin`、events(on/once/emit/bail/waterfall/parallel/serial)、reactive coeffect(provide/inject/get/set)。

明確排除(之後再說):isolate/intercept、logger service、traceable/shadow proxy、callable service、dotted service names、config validation、`Service` base class、loader/hmr/timer packages。

## 慣例

- 測試:RSpec,`bundle exec rspec`;spec/ 大致鏡射上游 `packages/core/tests/`(dispose/plugin/events/service/fiber/reflect)。
- commit 前只對變更的 .rb 檔逐一跑 `rubocop -A`(不要對 .yml 等非 Ruby 檔跑);`.rubocop.yml` 已關 Metrics 與 Naming/AccessorMethodName(`set_epoch`/`set_state` 對齊上游命名)。
- commit message 以英文為主。
