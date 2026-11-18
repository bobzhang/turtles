# Mutation testingをPR・coding agentで使える品質改善ループにする

Status: polished
Created: 2026-11-17
Updated: 2026-11-17
Branch: feat/diff-mutation-campaign-20261117
Priority: P0 (program coordination; 個別issueの既存優先度は変更しない)
Type: roadmap
PR: https://github.com/gpui-mbt/turtles.mbt/pull/46

## 概要と完了条件

turtles.mbtを「mutantを列挙してscoreを計算するCLI」から、PR差分で**信頼できる・費用が読める・対処できる**指摘を返し、テスト追加後に再検証できる道具へ育てる。mutation scoreの単純な最大化ではなく、判定の正しさ、対象選択の透明性、計算費用、人間にとっての有用性を別々に評価する。

**このissueの`polished`はプログラムの分割・依存・検証ゲートが確定した意味であり、各機能の実装準備完了ではない。** 実装PRでは後述の各トラックを独立したissueとして具体化する。このroadmap PR #46はdocs-onlyで、runtime/CLI/schema/CI gateを変更しない。

プログラムの完了条件は、(a) 差分キャンペーンで未実行と判定済みを区別できる、(b) 最適化で共通mutantのverdictを誤らない、(c) survivorに証拠と次の操作がある、(d) 同じ入力で再実行・監査できる、(e) 小規模fixtureと実モジュールで費用・有用性が実測されること。個々の段階は根拠付きで未実装・調査中・実装済みを管理する。

## 調査基点と既存機能

調査基点: main `423a360153bf2c46f7e4b47f5cdcb6a8114d9c76`（2026-11-17）。実装着手前にcurrent mainと関連PRを再照合する。

- 既存: parser ASTでの候補生成、comparison/boolean/arithmetic/literal/conditionとopt-in boundary/body、`--list`、`--file`、target-aware discovery。
- 既存: pristine baseline二度実行、隔離worker、`--jobs`、timeout、`--affected`（package単位test planning）、kill attribution、PBT witness/amplification。
- 既存: schema 3 report、pathとbyte offset等に基づくmutant ID、`--iterate` の全入力fingerprintによる保守的再利用。
- 未実装/未検証: validated diff selection、function/test依存cache、per-test coverageによる安全な選別、arid/equivalent管理、PR annotations/agent loop。
- **混同禁止**: 既存IDはoffsetを含むため、ソース行が移動してもIDが維持されるという契約はない。`--affected` は「どのtestを実行するか」であり「変更行のmutantだけを生成するか」とは別。

コード基点: [main](../../cmd/turtles/main.mbt) / [scanner](../../cmd/turtles/scanner.mbt) / [plan](../../cmd/turtles/plan.mbt) / [runner](../../cmd/turtles/runner.mbt) / [report](../../cmd/turtles/report.mbt) / [iterate](../../cmd/turtles/iterate.mbt)。

## 依存関係と作業単位

| トラック | 出すもの・責務 | 着手条件 / 終了ゲート |
| --- | --- | --- |
| D0 差分対象（最初） | [既存のpolished diff issue](20261013-diff-aware-mutation-selection.md)に従う`--in-diff FILE`実装PR。Gitの起動、schema 4仕様変更を勝手に混ぜない | 元issueのparser/new-side照合/byte交差/list-run一致/partial metadata/E2Eを満たす |
| D0b Git入力（後続） | `--since BASE`等のGit-facing wrapperを**別issue**として設計。参照revisionとcheckout、dirty tree、test-only diffの扱いを明文化 | D0の検証済みdiff入力契約が存在する。Git解決失敗を空集合へ変換しない |
| D1 再利用/増分cache | mutation identity・toolchain・target・test/manifest/source/設定・外部依存の失効証拠を記録。cold/warm比較 | まず依存推定のsoundnessをfixtureで証明。証拠不足はfull oracleへ戻し、既存`--iterate`を弱めない |
| D2 test単位選別 | `moon test --enable-coverage`とtest指定方法を**調査するspike** → 観測可能ならper-test選択の個別issue | coverageがtestごとに帰属できるかを検証。できなければ`--affected`/module-wideを維持する。テストを実行せず除外したmutantを`SURVIVED`と扱わない。実行済みで初期テストを通過したmutantの`SURVIVED`は、有効な解析（`--pbt-amplify`による`KILLED`への更新を含む）が完了するまで暫定とする。最終verdictは同じ設定のfull runの契約を維持し、到達性は別の証拠として記録する |
| D3 指摘の有用性 | survivorを未到達/到達したが検出されない/判定不能に分ける証拠モデル、arid/等価候補の理由付きレビュー、再現手順 | 自動でequivalentと断言しない。除外は明示的判断と履歴が必要。reportのscore分母変更は別契約 |
| D4 PR/agent連携 | partial reportに基づく注釈・件数上限・時間予算・`--only ID`相当の再検証・agent向け操作情報 | D0のscopeが監査可能。cache/coverageは利用可能時のみopt-in。未実行・timeout・setup errorを成功表示しない |

**依存順序**: D0は独立実装可。D1/D2はD0と並行で調査可。D3の人手分類モデルも独立で検証可。D4の差分PR gateはD0のscope/manifestを前提にする。D1/D2が未完成でもD4の最小版を阻止しない。ただしbudget中断後の件数・結果の注釈は、当該invocationに結び付いた進捗artifactまたは永続診断が利用可能になるまで導入しない。schema 4は共通フィールドを最初に導入するトラックが3→4へ移行し、D0は着地順に応じて導入または既存の4を共有する。[永続診断](20261013-persistent-run-diagnostics.md)・[sharding](20261013-deterministic-ci-sharding.md)の共通契約は既存polished indexに従う。

## 不変条件（すべての実装PRに適用）

1. **正しさ優先**: 同一toolchain/target/input/oracleでfull runと最適化runに共通するmutantのverdictが一致する。selection漏れを「全検証成功」と呼ばない。
2. **fail-safe**: diff不正/古いcontext/未検証source、cache失効不明、coverage不完全、test-plan不明では根拠のない`KILLED`/`SURVIVED`やscoreを作らない。適切な広い実行に戻るかsetup errorとして停止し、理由を記録する。
3. **scopeを記録**: discovered/selected/excluded/target-inactive/not-run/classifiedの件数と理由を区別する。timeout・budget超過・cancelled・errorは混同しない。空選択の100%は全体のmutation coverageを意味しない。
4. **oracleを守る**: pristine baseline、test実行隔離、既存timeout、`--iterate`の保守的失効、snapshot非更新を維持する。最適化がbaselineを無断で省略しない。
5. **再現性**: 結果にsource/config/test/manifest/toolchain/targetの識別情報、選択方式・予算・対象範囲を残す。人手acceptは理由・対象identity・見直し条件を監査できる。
6. **分母の誠実さ**: 部分scoreと全件score、mutant verdictとproof companionの`PROVED`を合算しない。coverage未観測はuncoveredを意味しない。CIではpartial/unknownをgreen扱いしない。

## 各トラックの受け入れ・検証計画

### D0: 既存issueが正本

[diff selection仕様](20261013-diff-aware-mutation-selection.md)の受け入れ条件を参照し、ここで別定義しない。特にUTF-8 byte spanと追加行の交差、rename/CRLF/EOF/invalid/stale、`--list`と実行の候補一致、target-inactiveの分離、schema 3→4、空diff・test-only diff・partial scoreを検証する。CIで`moon`系を実行した事実とこのdocs-only PRを混同しない。

### D1: cache（独立issueで確定する契約）

- [ ] Given test/source/manifest/config/toolchain/targetが変化、when依存が不明、then安全に全oracleへ戻る。単なるmutant元関数の同一性で他のtest変更を無視しない。
- [ ] Given cold/unchanged/one-line change、when同一環境で3回ずつ実行、then reuse hit/miss・失効理由・wall time・プロセス起動数を記録する。revision Aでcacheを作成後、testまたは推移的依存だけを変更したrevision Bのwarm runを、同じBのcacheなしfull runと比較し、選択mutant ID集合・全件verdictの一致を要求する。fixtureには、IDは不変だがAの再利用可能verdictとfresh Bのverdictが異なるmutantを少なくとも1件含め、warm Bがその古いentryを失効させfresh Bと一致することを検証する。
- [ ] Given同一入力・同一選択オプションのcacheなしfullとcacheあり、when比較、thenまず選択されたmutant ID集合の完全一致を要求し、その全件のverdict不一致0件を確認する。共通部分だけの比較で欠落・ID変更を見逃さない。ハッシュのみを信頼境界にせず、衝突・破損・並行書込みを拒否または安全に再計算する。
- [ ] 手法の比較（function graph、test graph、manifest依存）と観測不能な依存（FFI、環境、生成物）をissueに列挙する。未確認の速度改善を公称しない。

### D2: coverage/test selection（先にspike）

- [ ] Moon公式のcoverage出力が**per-test attribution**を提供するか、集約されたline coverageのみか、実toolchain/targetで確認して証拠を残す。
- [ ] Given test単位マップが欠落・古い・target不一致・動的経路不明、when選択、then広いtest planへ戻る。
- [ ] Given被験moduleの小/大・public/white-box/property test、when同一入力・同一mutant選択オプションでfull test vs filtered test、thenまず選択されたmutant ID集合の完全一致を要求し、その全件のverdict一致・選択されたtest数・時間を記録する。testの絞り込みでmutantを欠落させず、共通部分だけでは比較しない。未到達判定にはcoverageの信頼度を添える。`--pbt-amplify`有効時のseed・trial変更で初めてkillする場合と、amplified pristine controlが失敗する場合もparity fixtureに含める。その解析フェーズでfilterの妥当性が検証されるまでは、amplificationのoracleを未フィルタのまま維持する。同一timeout設定でfullが`TIMEOUT`、filteredが`SURVIVED`/`KILLED`となるfixtureも含め、timeoutによるverdict差が生じる条件ではfiltered結果を同等とせずfull oracleへ戻る。
- [ ] per-testが不可能なら**no-go**を記録し、無理なAST call graph選別を実装しない。

### D3: actionable findings

- [ ] Given`SURVIVED`、when分類、then「未到達」「到達・未検出」「証拠不足」を分け、評価したsuiteの入力・toolchain・targetに結び付いたcoverage等の到達性証拠とkill attributionを使う。生成PBT harnessのwitnessは追加テスト入力の提案であり、元suiteが変異式に到達した証拠にはしない。変異式そのものの評価を識別できる証拠を要求し、同じ行のhitだけでは到達としない（例: `enabled && x < limit`の短絡で`<`が未評価）。suiteのcoverageが不完全、または変異箇所の評価を区別できない場合は「証拠不足」とし、到達・未到達のどちらも断定しない。
- [ ] Given arid/equivalent候補、whenaccept、then理由・reviewer・対象identity・影響するreport指標を記録し、未acceptのsurvivorを自動抑制しない。
- [ ] Given無価値/有価値な代表mutant、when人手レビュー、then有用性ラベルの定義、評価件数、合意不一致、誤抑制率を公開し、調整可能にする。
- [ ] コード削除・kill matrix・テスト簡素化は提案止まり。機械的なテスト削除や本体変更はこのprogramの副作用にしない。

### D4: PR/agent integration

- [ ] Given`--in-diff`の完了report、whenCI注釈、then現在のinvocation ID・PR入力との一致を検証してからsource path/line/mutant ID/根拠/再実行手順と注釈件数の上限を示す。一致を確認できないreportは公開せず、古い完了reportが残った状態でbaseline/setupが失敗しても前回のfindingsを現在のPRへ注釈しない回帰fixtureを含める。budget中断後の未実行件数・途中結果は、invocation IDと入力・選択集合に結び付いた別の進捗artifactまたは永続診断を根拠にする。完了reportから未完了runの進捗を推定せず、前回reportを流用しない。根拠がなければ件数不明・未完了と表示し、budgetベースの注釈は保留する。
- [ ] Given同一identity、when`--only ID`相当で再実行、then対象外の結果を暗黙に「成功」とせず、再検証対象と入力変更を表示する。offset依存の現行IDをそのまま編集間stableと主張しない。
- [ ] Giventestを追加/更新、when再実行、then以前のsurvivorがkillされたか、未検証かを区別する。agent自身が証拠なしでacceptやtest rewriteを実行しない。
- [ ] GivenPRがtest-only、diffなし、CI cancelled、time budget exceeded、baseline fail、whenCheck出力、thenpartial/unknown/setup errorを明示。初期PR gateは通知中心で始め、実測後にhard gateを別途判断する。

## 計測とrollout gate

| 指標 | 測り方 | 初期合格/判断 |
| --- | --- | --- |
| Correctness | 同一fixtureでD0はdiff交差契約に基づく期待mutant ID集合との一致、同一選択scopeのD1/D2はfull/optimizedのID集合完全一致を検証後、対象全件のverdictを比較 | ID集合・verdictの不一致0。共通部分だけでは比較せず、比較できない条件はno-evidenceと報告 |
| Performance | cold/warm/diff、各3試行、wall time・実行回数・cache失効理由 | 基準値を先に記録。改善目標は測定後に設定 |
| Completeness | selected/classified/pending/skipped/inactiveと理由の収支 | 無理由の除外0。partialを全件と表示しない |
| Actionability | 人手確認済み指摘のうち対処可能な件数、誤抑制・判断保留 | 分母・件数・基準を公開し、他社論文の数字を達成済みと扱わない |
| Reproducibility | 固定入力/target/toolchainの再実行とID・scope比較 | 差異を再現して説明可能。非決定性は検出して明示 |

評価対象は(1)決定的fixture、(2)turtles自身の小規模module、(3)`gpui.mbt`等の実モジュール候補。規模・OS・Moon version/target・入力SHA・利用オプションを添える。実module測定は未実施であり性能・有用性を先取りして主張しない。Google研究における「actionable」の母集団はturtlesのsurvivor全体と一致しないため、75%等をそのまま合格閾値にしない。

## 非目標・分割規則

- このroadmap PRで`--in-diff`/`--since`/cache/coverage/reporterを実装しない。新CLIの仕様やschemaを上書きしない。
- Googleの実装、TypeScript/Vitest前提のmutator機能をMoonBitで無検証に移植しない。
- coverage不明を安全に選別できたと見なさず、arid/equivalentの推測を機械的に合格扱いしない。
- 総mutation scoreを単独KPIにしない。PR subset scoreをglobal scoreと合算しない。
- 自動mergeしない。各機能の実装・テスト・CI根拠は独立PRで報告する。

## このroadmapのpolish受け入れ

- [x] current mainの既存機能と新規提案を分離し、既存のdiff issueを正本として参照する。
- [x] 段階・依存・安全側fallback・個別exit gate・測定方法を文書化する。
- [x] 個別トラックで未検証の技術前提（per-test coverage、cache依存等）をspike/no-go扱いにする。
- [x] docs-onlyとruntime検証を分離する。
- [ ] D0〜D4の実装・E2E完了（このPRの完了条件ではない）。

## Verification（PR #46 docs-only）

- [ ] `git diff --check` — 未実行。
- [ ] `moon fmt --check` / `moon check --target native --deny-warn` / `moon test --target native` — 未実行。MoonBit source変更なし。
- [ ] fixture E2E / native・js・all matrix — 未実行。将来の個別実装PRで必要。
- [ ] GitHub CI — 最新HEADでの確認結果をPRに別途記録。

## 参考

- [mizchi: mutation testingでテスト品質を評価する](https://zenn.dev/mizchi/articles/mutation-test-quality)
- [Google: State of Mutation Testing at Google](https://research.google/pubs/state-of-mutation-testing-at-google/)
- [Google: Practical Mutation Testing at Scale](https://research.google/pubs/practical-mutation-testing-at-scale-a-view-from-google/)
- [mizchi/mutator](https://github.com/mizchi/mutator) — diff・agent feedback・accepted reason・report。MoonBitと仕様は同一ではない
- [cargo-mutants: --in-diff](https://mutants.rs/in-diff.html)
- [MoonBit公式 coverage](https://docs.moonbitlang.com/en/stable/toolchain/moon/coverage.html)

## 変更履歴

- 2026-11-17: PR #46にopen roadmapとして追加（実装・テストなし）。
- 2026-11-17: 既存diff issueを正本として保持し、依存・段階別ゲート・fail-safe・計測・no-goを確定。`issues/open/`から`issues/polished/`へ移動（実装済みではない）。
