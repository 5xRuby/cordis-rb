# cordis-rb — agent notes

實驗性練習專案:用 Ruby 重實作 Cordis(TS plugin/生命週期 meta-framework)的核心機制。不求生產可用,型別安全不是考量重點。優先順序是「機制正確」而不是 API 表面覆蓋率。

## 正式定義查詢

理論來自論文 *"A Programming Paradigm for Spatiotemporal Composability"*。不確定正式定義時,查 NotebookLM(內有 paper.pdf、cordis GitHub、deepseek-harness GitHub),不要憑印象猜:

```
notebooklm ask "..." --notebook b4683395-8795-47c8-9d7a-76f058954f06
```

## 論文模型 → 程式碼對應

- **Revertible effect**:effect 為 Γ → Γ × (Γ → Γ)。`Context#effect` 的 block 立即套用副作用、回傳 inverse(callable);`@disposables` stack 就是 φ accumulator,`dispose` 嚴格 LIFO 撤除。
- **Theorem 16**:單一 component 內嚴格 LIFO 即可正確復原 non-commutative 效果。關鍵區分是 commutative vs non-commutative,不是「新增 vs 修改」。跨 component 共用 non-commutative 資源的撤除順序,靠 coeffect 機制顯式宣告依賴(尚未實作)。
- **Reactive coeffect**(service injection 的正式基礎,尚未實作):coeffect context Σ 是 dependent partial function;σ → σ' 時依「不滿足→滿足」/「滿足→不滿足」分類成 activating/deactivating,觸發 load/teardown。provider 卸載時依賴者先 teardown,順序由機制保證。

## 已定案的設計決策

- **API 命名仿 Cordis**(使用者確認):`ctx.effect` / `ctx.dispose` / `ctx.extend`(未來 `ctx.on`)。`Context#extend` 刻意遮蔽 `Object#extend`。
- **併發用 async gem(Fiber-based)**,對應 TS event loop 的協作式併發。不要用 Thread+Mutex 硬幹。目前 Context+disposal 層還不需要,coeffect 層才引入。
- async 模式參考 `/Users/ryudo/RubyPrjs/lens-ruby-async`:完成訊號用 `Async::Queue` 不用 `Async::Condition`(signal 先於 wait 會遺失)、spec 用 `task.with_timeout` 包可能吊死的流程、teardown 逐步各自 rescue。

## 範圍紀律

第一版只做:Context tree + effect LIFO disposal(已完成)+ reactive coeffect service injection(下一步)。waterfall 事件鏈、hot-reload config diff reconciliation 明確排除——骨架穩之前做了只是模仿 API 表面。

## 慣例

- 測試:RSpec,`bundle exec rspec`;spec/ 鏡射 lib/。
- commit 前只對變更的 .rb 檔逐一跑 `rubocop -A`(不要對 .yml 等非 Ruby 檔跑)。
- commit message 以英文為主。
