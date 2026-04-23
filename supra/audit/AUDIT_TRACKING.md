# ONE Audit Tracking Log

Tracks external AI auditor submissions and findings across R1 → R2 → R3.

## Auditor roster

| # | Auditor | Platform | URL |
|---|---|---|---|
| 1 | Gemini | Google | gemini.google.com / API |
| 2 | Grok | X.ai | grok.x.ai |
| 3 | Qwen | Alibaba | chat.qwen.ai / API |
| 4 | Kimi | Moonshot | kimi.ai |
| 5 | DeepSeek | — | chat.deepseek.com |
| 6 | ChatGPT | OpenAI | chat.openai.com |
| 7 | Perplexity | — | perplexity.ai |
| 8 | Claude (fresh) | Anthropic | claude.ai |

## Round 1 findings aggregator

### Submission checklist

- [x] Gemini R1 submitted (2026-04-23)
- [ ] Grok R1 submitted (unreachable this session)
- [x] Qwen R1 submitted (2026-04-23)
- [x] Kimi R1 submitted (2026-04-23, late)
- [x] DeepSeek R1 submitted (2026-04-23)
- [ ] DeepSeek R1 submitted
- [ ] ChatGPT R1 submitted
- [ ] Perplexity R1 submitted
- [ ] Claude fresh R1 submitted

### Findings log (R1)

Format: `[SEVERITY] <auditor> — <location>: <finding> → <fix/no-fix rationale>`

**Gemini R1 (2026-04-23):**
- [CRITICAL] Gemini — `price_8dec()` line 140-145: no `assert!(v > 0)`; oracle zero → div-by-zero abort in `liquidate` (line 370), `redeem_from_reserve` (line 333), `redeem_impl` (line 276) → **FIX**: add `E_PRICE_ZERO` error + `assert!(v > 0, E_PRICE_ZERO)` post-oracle call.
- [HIGH] Gemini — `STALENESS_MS = 3_600_000` (line 31): 1h window too permissive for volatile L1 collateral; enables mint-side over-extension + liquidation-delay bad-debt when oracle lags. Gemini's specific reserve-drain scenario had direction inverted but general drift-risk argument valid. → **PENDING DATA**: need real pair-500 update cadence to decide between 300s/900s/keep-3600s. Tentative target: 900_000 (15 min).
- [MEDIUM] Gemini — `liquidate()` economics: 2.5% of debt bonus to liquidator may not cover gas+risk for dust troves (MIN_DEBT=1 ONE ≈ $1, bonus ≈ $0.025) → accumulates dust bad-debt tail. → **ACCEPT + DOCUMENT** (tiered bonus adds complexity disproportionate to tail).
- [INFO] Gemini — `redeem_impl()`: caller-specified target vs Liquity's auto-lowest-CR. → **ACCEPT** (conscious design, offloaded to frontend indexer).
- [LOW] Gemini — `liquidate()` line 393: `product_factor` integer div rounds down. → **ACCEPT** (pro-protocol, SP depositor loses dust).
- [REJECTED] Gemini extra suggestion — add CR<200% check in `redeem_impl`: would break redemption in normal state when all troves >MCR; `redeem_from_reserve` already serves healthy-state peg floor.

Gemini verdict: **NEEDS FIX BATCH** (F1 + F2 + F3 discussion).

**Qwen R1 (2026-04-23):**
- [CRITICAL] Qwen C-01 — `price_8dec()`: div-by-zero on oracle value=0. → **DUPLICATE of Gemini F1** — consolidated into single fix.
- [HIGH→LOW] Qwen H-01 — `price_8dec()` staleness check on `ts_ms=0`: Qwen claimed stale check passes for first 3.6M ms post-deploy. Trace: for any running chain (Supra mainnet is old), `now_ms >> 3.6M`, so `ts_ms=0` → check fails → E_STALE fires correctly. Qwen's HIGH rating wrong for real mainnet. Still, `assert!(ts_ms > 0, E_STALE)` is cheap defensive code. → **FIX (downgraded to LOW)**.
- [HIGH→LOW] Qwen H-02 — `sp_settle` `as u64` cast overflow: Move `as u64` aborts on overflow, not silent truncate. Realistic threshold requires trillions of ops + dust SP + massive fees simultaneously. Unrealistic. → **ACCEPT**; document as asymptotic limit alongside product_factor cliff.
- [MEDIUM→INFO] Qwen M-01 — fee rounding for `amt < 4`: unreachable because MIN_DEBT=1 ONE ⇒ fee ≥1e6 ⇒ burn_amt ≥250000. → **N/A**.
- [MEDIUM] Qwen M-02 — product_factor decay cliff: spec already acknowledges ~15-pool-liq limit; code line 183 handles P=0 via early return (no panic). Hard to encode a safe mainnet guard without false-tripping. → **ACCEPT + document in WARNING const**.
- [MEDIUM] Qwen M-03 — `pow10(n)` overflow if oracle dec > 38: valid defensive concern. → **FIX**: add `assert!(n <= 38, E_DECIMAL_OVERFLOW)`.
- [LOW] Qwen L-01 — reentrancy surface: Move structurally safe. → **ACCEPT**.
- [INFO] Qwen I-01/02/03 — positives (oracle-free close, strict total_sp check, u256 intermediates). → **MAINTAIN**.

Qwen verdict: **NEEDS FIX BATCH** (C-01 + H-01 + M-01 clarification + M-02 doc).

**DeepSeek R1 (2026-04-23):**
- [LOW] DeepSeek L-01 — rounding direction on USD→SUPRA conversion: floor truncation favors target (leftover stays in treasury). Minor (<1 SUPRA/liq). → **ACCEPT** (pro-protocol, duplicates Gemini F5).
- [LOW] DeepSeek L-02 — product_factor precision degradation: duplicates Qwen M-02. → **ACCEPT + doc**.
- [INFO] DeepSeek I-01 — genesis trove permanent lock: deployer post-null-auth can't `close_trove`. Redemption CAN drain it (target=genesis). → **ACCEPTED DESIGN**.
- [INFO→LOW] DeepSeek I-02 — NEW FINDING: `price_8dec()` staleness check has no upper bound on `ts_ms`. A far-future oracle timestamp bypasses staleness. Kimi-style trust-model dep, but cheap defensive fix. → **FIX**: add `MAX_FUTURE_DRIFT_MS = 60_000` const + `assert!(ts_ms <= now_ms + MAX_FUTURE_DRIFT_MS, E_STALE_FUTURE)`.
- [INFO] DeepSeek I-03 — immutable params may become suboptimal: meta-observation, explicit design. → **ACCEPT**.
- [NIT] DeepSeek N-01 — variable naming `sr` shadowing. → **IGNORE** (style).

**DeepSeek missed**: C-01 oracle-zero (caught by Gemini+Qwen), M-03 pow10 dec>38 (caught by Qwen). Less thorough.

DeepSeek verdict: **PROCEED TO PUBLISH** — **overridden** by stricter findings from Gemini+Qwen.

**"hy3" R1 (2026-04-23)** — **outside-roster bonus auditor**. Findings valid & folded into fix batch. NOT counted toward the 8-auditor R3 GREEN gate.
- [CRITICAL] hy3 F1 — future-timestamp bypass on `price_8dec()`: duplicate DeepSeek I-02 with severity upgraded CRITICAL. → **FIX** (already in batch): `assert!(ts_ms <= now_ms, E_STALE_FUTURE)`.
- [CRITICAL] hy3 F2 — **NEW**: u64 overflow in fee math at lines 158, 229, 274, 331. Abort (not silent) but creates hard ~$1.84B ONE supply ceiling on immutable contract. → **FIX**: cast operands to u128 before `×`, cast back to u64. 4 call sites. Standard pattern already used at line 224.
- [HIGH] hy3 F3 — oracle zero-price: duplicate Gemini F1/Qwen C-01. → **FIX** (already in batch).
- [LOW] hy3 F4 — liquidator incentive small troves: duplicate Gemini F3. → **ACCEPT + DOC**.
- [LOW] hy3 F5 — product_factor precision: duplicate Qwen M-02. → **ACCEPT + DOC**.
- [INFO] hy3 F6 — genesis trove stuck (1% fee blocks close): verified true post-null-auth. → **ACCEPTED DESIGN**.
- [INFO] hy3 F7 — reentrancy structurally impossible: duplicate. → **ACCEPT**.

hy3 verdict: **NEEDS FIX BATCH** (F1 + F2 + F3 critical/high).

**openhands R1 (2026-04-23)** — **outside-roster bonus auditor**. Not counted toward 8-auditor gate.
- [HIGH] openhands H-1 — oracle zero-price div-by-zero: **4th confirmation** (Gemini+Qwen+hy3+openhands). → **FIX** (already in batch).
- [MEDIUM] openhands M-1 — product_factor decay ~50+ liq: duplicate Qwen M-02 (estimate differs 15 vs 50, no impact on fix). → **ACCEPT + DOC**.
- [MEDIUM→LOW] openhands M-2 — **NEW**: liquidation CR<110% zone: SP absorbs `debt` ONE but receives <debt worth SUPRA (bad-debt loss to SP). Spec-accepted (failure mode: "SUPRA -90% system-wide"). Fix would need CR-floor gate or bonus-scaling (complexity). → **ACCEPT**, extend WARNING const: "SP may take a loss on liquidations of troves with CR<110%".
- [LOW/INFO] openhands positives — Liquity-P math, supply invariants, Move reentrancy safety, strict total_sp check, u256 intermediates, null-auth. → **MAINTAIN**.

**openhands missed**: u64 fee overflow (hy3), pow10 dec>38 (Qwen), future-ts bypass (DeepSeek+hy3), ts_ms=0 defensive (Qwen). Lenient tier.

openhands verdict: **NEEDS FIX BATCH** — consistent with roster majority.

**Kimi K2.6 R1 (2026-04-23, arrived late):**
- [HIGH] Kimi H-1 — oracle future-timestamp bypass: 3rd auditor (hy3, DeepSeek, now Kimi) to flag. Kimi recommends symmetric ±1h window (`assert!(ts_ms <= now_ms + STALENESS_MS)`); R1 fix used tighter `MAX_FUTURE_DRIFT_MS = 60_000`. → **IN R1 FIX BATCH**. Note: R2 discuss whether 1m tight bound or 1h symmetric is correct.
- [MEDIUM] Kimi M-1 — product_factor precision decay: **6th auditor to flag**. Kimi says document only (no code fix possible post-deploy); R1 fix applied cliff guard abort-before-P=0. Kimi would accept the doc-only approach. → **IN R1 FIX BATCH** (stronger than Kimi's recommendation).
- [MEDIUM] Kimi M-2 — fee split rounding <4 units: duplicate Qwen M-01. Unreachable because MIN_DEBT enforcement. → **ACCEPT**.
- [LOW] Kimi L-1 — genesis trove permanent sink: duplicate DeepSeek I-01, hy3 F6. → **DOCUMENTED in WARNING**.
- [LOW] Kimi L-2 — SP reward rounding dust: duplicate Gem3.0 F5, DeepSeek L-01. → **ACCEPT**.
- [LOW] Kimi L-3 — liquidator incentive dust troves: duplicate Gem3.0 F3, hy3 F4. Kimi suggests deploying with MIN_DEBT ≥ 10-100 ONE (spec change). → **DEFERRED D2**.
- [INFO-1/2/3] Kimi positives — reentrancy immunity, supply invariants verified, null-auth correctly structured. → **MAINTAIN**.
- [NIT] Kimi NIT-1 — `price()` should be `#[view]`: **FALSE POSITIVE** — line 478 already has `#[view]` annotation. Kimi misread source. → **REJECT**.

Kimi missed: oracle `v=0` zero-price (5 auditors CRIT/HIGH), u64 fee overflow (hy3 CRIT), pow10 dec>38 (Qwen MED), post-redeem debt invariant (Gem3.1), 25% burn deflation gap (Gem3.1). Lenient tier like DeepSeek + openhands.

Kimi verdict: **PROCEED TO PUBLISH with HIGH-1 fix** — consistent with roster majority's NEEDS-FIX-BATCH since HIGH-1 is blocking.

**"gemini 3.1" R1 (2026-04-23)** — label ambiguous (Gemini 3.1 model vs separate run of Gemini), TREATED AS DISTINCT auditor pending clarification.
- [CRITICAL] gemini3.1 F1 — product_factor asymptotic decay to 0: **5-auditor convergence** (Qwen/DeepSeek/hy3/openhands/gemini3.1), severity LOW→CRITICAL spread. Verified: at ~18-19 near-depletion liqs, P truncates to 0, wipes SP balances permanently via `initial × P / snap_p` in sp_settle. → **FIX**: add `MIN_P_THRESHOLD = 1e9` guard — abort liquidation if post-update P would drop below threshold. Preserves existing SP, accepts bad-debt accumulation past threshold. Trivial complexity.
- [HIGH→LOW] gemini3.1 F2 — micro-trove SP drain via redeem_impl: severity overstated (redemption improves CR, attack requires separate oracle shock), but cheap defensive add. → **FIX**: `assert!(t.debt == 0 || t.debt >= MIN_DEBT, E_DEBT_MIN)` post-redeem.
- [MEDIUM] gemini3.1 F3 — **NEW**: systemic wind-down deflation via 25% fee burn. Circulating supply ≈ 99.75% of total_debt. Full wind-down structurally impossible. Fix requires spec change (burn → reserve_one route). → **ACCEPT + DOC**: extend WARNING const with explicit deflation-wind-down note.
- [LOW] gemini3.1 F4 — oracle zero-price: 5th confirmation. → **FIX** (already in batch).
- [INFO] gemini3.1 F5 — oracle-free close_trove escape hatch: positive. → **MAINTAIN**.

gemini 3.1 missed: u64 fee overflow (hy3), pow10 dec>38 (Qwen), future-ts bypass (DeepSeek+hy3), ts_ms=0 defensive (Qwen). Inconsistent with Gemini R1 original (which caught STALENESS_MS issue).

gemini3.1 verdict: **NEEDS FIX BATCH**.

---

## Round 2 (after R1 fix batch)

### Fix batch R1 applied (2026-04-23, ONE v0.2.0)

Roster collected: 3/8 (Gemini 3.0, Qwen, DeepSeek). Bonus: hy3, openhands, gemini 3.1. Kimi skipped per user. API retry of Gemini/Qwen/Groq blocked by quota/key/TPM. Proceeding to R2 with 6-audit dataset.

Patch summary (all fixes in `sources/ONE.move`, package bumped `0.1.0 → 0.2.0`):
1. `price_8dec()` hardening — 4 new asserts:
   - `assert!(v > 0, E_PRICE_ZERO)` — oracle zero-price (Gem3.0 CRIT, Qwen CRIT, hy3 HIGH, openhands HIGH, Gem3.1 LOW)
   - `assert!(ts_ms > 0, E_STALE)` — defensive ts=0 (Qwen H-01)
   - `assert!(ts_ms <= now_ms + MAX_FUTURE_DRIFT_MS, E_STALE_FUTURE)` — future-ts bypass (DeepSeek I-02, hy3 F1 CRIT)
   - Const `MAX_FUTURE_DRIFT_MS = 60_000`
2. `pow10()` bounds — `assert!(n <= 38, E_DECIMAL_OVERFLOW)` (Qwen M-03)
3. Fee-calc u128 casts at 4 call sites (hy3 F2 CRIT):
   - `route_fee_fa` line ~158 (burn_amt)
   - `open_impl` line ~229 (fee)
   - `redeem_impl` line ~274 (fee)
   - `redeem_from_reserve` line ~331 (fee)
4. `liquidate()` cliff guard (Gem3.1 F1 CRIT, Qwen M-02, DS L-02, hy3 F5, OH M-1):
   - Const `MIN_P_THRESHOLD = 1_000_000_000`
   - Preview `new_p`, assert `new_p >= MIN_P_THRESHOLD` before commit
   - Mirrored into `test_simulate_liquidation` test helper for coverage
5. `redeem_impl` post-redeem debt invariant — `assert!(t.debt == 0 || t.debt >= MIN_DEBT, E_DEBT_MIN)` (Gem3.1 F2)
6. `WARNING` const extended with 5 numbered known-limitations (SP cliff, u64 asymptotic, genesis lock, CR<110% SP loss, 0.25% deflation gap). Prefix + signature preserved so existing test passes.
7. New error codes: `E_PRICE_ZERO = 11`, `E_STALE_FUTURE = 12`, `E_DECIMAL_OVERFLOW = 13`, `E_P_CLIFF = 14`.

Test results: 16/16 pass (15 existing + new `test_liquidation_cliff_guard_aborts` verifying E_P_CLIFF fires at P drop below 1e9).

Deferred (not in R1 batch, to reconsider R2):
- **STALENESS_MS reduction** from 3600s → 900s (Gem3.0 F2 HIGH, single-auditor concern, no consensus). Flagged for R2 discussion.
- **Liquidator 2.5% dust tail** (Gem3.0 F3 MED, hy3 F4 LOW) — accepted, covered by WARNING doc indirectly.
- **25% burn → reserve_one route** (Gem3.1 F3 MED) — spec-level change, not a patch. Covered by WARNING doc.

### Re-submission checklist
- [ ] All 8 auditors re-submitted with R1-patched source (roster: 3/8 captured, 5 pending)

### Findings log (R2)

**Gemini R2 (2026-04-23):**

*R1 fix validation:* all 8 fixes verified correct, no regressions. Cliff guard trade-off endorsed.

*Fresh findings:*
- [MEDIUM] Gemini R2-01 — WARNING doc imprecise re: deflation gap. Current text says 0.25% per cycle, but individual debtor-perspective = 1% shortfall per trove (minted 99%, needs 100% to close). Aggregate supply/debt gap varies 0.25% (SP non-empty) to 1% (SP empty). → **R2 FIX**: tighten WARNING wording to distinguish aggregate burn (0.25%–1%) vs debtor shortfall (1% per trove, needs secondary-market ONE).
- [LOW] Gemini R2-02 — `liquidate()` line 382: `total_seize_supra = ((total_seize_usd * 1e8 / price) as u64)` can overflow u64 cast at extreme low SUPRA price + large trove. Threshold: `total_seize_usd/price > 1.84e19/1e8`. Reachable with debt ≥1000 ONE + SUPRA <$0.006. Same pattern lines 384 (liq_supra), 386 (reserve_supra). → **R2 FIX**: compute in u128, cap vs `(coll as u128)`, cast to u64 last.

*Deferred answers:*
- **D1 (STALENESS_MS)**: 900s (15 min). Reason: flash crashes can move 25% in 15-30 min; 1h window exceeds reaction time for 150% liq threshold. 2nd auditor to recommend 900s (Gem3.0 was 1st).
- **D2 (liquidator dust)**: Accept as WARNING-documented. Low gas on Supra + min-floor complexity not worth it.
- **D3 (25% burn)**: Accept. Core purist design, reserve_one route would introduce governance/complexity contradicting philosophy.

Gemini R2 verdict: **PROCEED TO PUBLISH** — R2-01 doc tweak + R2-02 u64 guard are non-blocking cleanups.

**Qwen R2 (2026-04-23):**

*R1 fix validation:* all 8 fixes endorsed. Notable math check: `pow10(n <= 38)` bound exactly matches u128 capacity (10^38 < 2^128-1 < 10^39). Guard ordering, error code sequencing, cast semantics all verified sound.

*Fresh findings:*
- [MEDIUM] Qwen R2-F2 — `route_fee_fa` line 178-179: when `r.total_sp == 0`, **100% of fee burned** (not just 25%). Remaining 75% has no SP to absorb so it gets burned too. Aggressive deflation during SP-empty states. Qwen recommends accept + document. → **R2 DOC**: extend WARNING (5) to note "during SP-empty windows, 100% of fees burn; the 0.25% aggregate gap becomes 1% during such periods".
- [MEDIUM] Qwen R2-F3 — `liquidate` lines 384-389: asymmetric loss allocation under CR<110%. Math trace confirmed: liquidator + reserve retain nominal 2.5% each; SP alone absorbs the shortfall. Aligns with accepted "CR<110% SP loss" but WARNING (4) doesn't explicitly state the priority ordering. → **R2 DOC**: tighten WARNING (4) to state "liquidator and reserve retain nominal caps; SP absorbs full collateral shortfall, deviating from 25/25/50 nominal split".

*Deferred answers:*
- **D1 (STALENESS_MS)**: 900s — **3rd auditor concurring** (Gem3.0, Gemini R2, Qwen R2). Reason: 1h excessively long for a stablecoin peg; 300s too tight given Supra block sync; 900s optimal balance.
- **D2 (liquidator dust)**: Accept + doc. `MIN_DEBT` bounds absolute loss per dust trove to ~$1.50.
- **D3 (25% burn)**: Accept + doc. Intentional deflationary mechanic per purist philosophy; routing to reserve_one breaks invariant.

Qwen R2 verdict: **PROCEED TO PUBLISH** — F2+F3 are doc-only; R1 batch is "rigorously implemented".

**ChatGPT R2 (2026-04-23)** — note: **multiple findings incorrect or would cause regressions**. Verdict not trusted without filtering.

*R1 fix validation:*
- R2-1 (oracle v=0 guard): ✅ PASS, endorses.
- R2-2 (timestamp guards): ✅ PASS with note — `now_seconds()` 1s resolution means sub-second boundary is theoretical MEV window. Acceptable.
- R2-3 (pow10 bound): ❌ **INCORRECT**. ChatGPT claims `n <= 38` fragile because 10^38 near u128 max. Math: 10^38 < 2^128-1 < 10^39. 2.4× safety margin. Qwen R2 already confirmed bound is exact. → **REJECT**.
- R2-4 (u128→u64 "silent truncation"): ❌ **INCORRECT**. Move `as u64` aborts on overflow, not silent truncation. And for fee pattern `amt*BPS/10000`: division by 10000 always reduces magnitude below u64::MAX. → **REJECT**.
- R2-5 (MIN_P_THRESHOLD halting): ⚠ valid design concern, already accepted trade-off. Liquity epoch/scale rejected for purist philosophy. → **DOCUMENTED**.
- R2-6 (dust graceful-zero suggestion): ❌ **WRONG FIX**. ChatGPT suggests `if (t.debt < MIN_DEBT) t.debt = 0;`. This breaks supply-debt invariant — would create unbacked circulating ONE. Current revert-on-dust is correct. → **REJECT**.

*Fresh findings:*
- [HIGH] R2-7 `total_sp > debt` should be `>=`: ❌ **CRITICAL REGRESSION PROPOSAL**. Memory spec explicitly: "v0.2 audit: 1 CRITICAL fix (`total_sp > debt` strict — prevents P=0)". Line 375 comment documents the intent. Applying this fix would reintroduce fixed bug. → **REJECT, BLOCK FROM R3 BATCH**.
- [MED] R2-8 rounding leakage in liq splits: partial overlap Qwen R2-F3. Sub-cent impact. → **ACCEPT**.
- [HIGH] R2-9 oracle SPOF: duplicate Gem3.0 / already in WARNING header. Known design constraint. → **ACCEPTED DESIGN**.
- [LOW] R2-10 unbounded total_debt: theoretical u64 ceiling 1.84e11 ONE. → **ACCEPT + optional DOC**.

*Deferred answers:*
- D1: 900s (**4th auditor** concurring). Reason: 1h dangerously long for DeFi, 900s balance vs 300s liveness risk.
- D2: Accept as documented limitation.
- D3: Keep as-is. Matches purist philosophy.

ChatGPT R2 verdict: **NEEDS FIX BATCH** — but rationale depends heavily on incorrect R2-7 proposal that would be a REGRESSION if applied. True signal after filtering: 1 valid concern (R2-5, already accepted) + 1 minor (R2-8). Effective verdict should be PROCEED, not NEEDS-FIX.

**DeepSeek R2 (2026-04-23):**

*R1 fix validation:* all 8 fixes endorsed with good math analysis. Matches Qwen's verification depth.

*Findings:* (DeepSeek's self-correcting pattern evident — many findings conclude "false alarm" or "mitigated by cliff guard")
- R2-1 `total_debt` underflow: DeepSeek self-concludes "false alarm, logic sound". ✅ No issue.
- R2-2 `close_trove` oracle-free: positive observation. ✅
- R2-3 Fee-burn rounding small amt: duplicate Qwen M-01, unreachable. ✅ Accept.
- R2-4 Zero-debt trove redeem griefing: DeepSeek self-verifies impossible (assert `t.debt >= net` blocks). ✅
- R2-5 Self-redemption allowed: valid doc observation. Economically partial-repay + collateral-withdraw + 1% fee tax. → **DOCUMENT in spec/WARNING for R3**, no code change.
- [MED] R2-6 SP loss from price drop at CR 110-150%: DeepSeek scenario verified. **Already covered by WARNING (4)**. DeepSeek's proposed `assert!(collateral_value_usd >= debt, E_SP_LOSS)` fix would leave bad-debt as un-liquidatable zombies (worse outcome). → **REJECT fix, ACCEPT as spec**.
- R2-7 `total_sp` zero post-liq div-by-zero: DeepSeek self-walks through, concludes cliff guard + u256 mitigate. ✅ No issue.
- [MED] R2-8 `redeem_from_reserve` missing `total_debt -= net`: ❌ **MISINTERPRETATION**. `total_debt` tracks Σ t.debt (trove-level), not circulating supply. Reserve-redeem burns ONE but no trove debt changes. Adding DeepSeek's proposed update would desync `total_debt` from actual sum. This is the intended deflation-gap mechanism (D3). → **REJECT fix, CURRENT CORRECT**.
- R2-9 `debt == 0` in liquidate: DeepSeek verifies E_HEALTHY fires. ✅ No issue.

*Deferred answers:*
- **D1 (STALENESS_MS)**: 900s — **5th auditor concurring** (Gem3.0, Gem R2, Qwen R2, ChatGPT R2, DeepSeek R2). Overwhelming consensus.
- **D2 (liquidator dust)**: Accept. Noted SP is backstop, liquidation absence doesn't create systemic risk.
- **D3 (25% burn)**: Accept. Purist deflationary feature.

DeepSeek R2 verdict: **PROCEED TO PUBLISH** with optional improvements (D1 change + document self-redemption). All "findings" are either self-correcting, doc-level, or misinterpretations. Clean endorsement of R1 fix batch.

---

## Round 3 (final)

### Fix batch R2 applied (2026-04-23, ONE v0.3.0)

R2 roster collected: 4/8 (Gemini, Qwen, ChatGPT, DeepSeek). User-decided sufficient. Grok unreachable; Kimi/Perplexity/Claude-fresh skipped.

**R2 patch summary** (package 0.2.0 → 0.3.0):

1. **STALENESS_MS: 3_600_000 → 900_000** (15 min) — **D1 resolution**, 5/5 R2 auditor consensus (+ Gem3.0 R1 = 5 unique votes).
2. **WARNING const tightening** — 3 precision items + new item (6):
   - (4) now: "liquidator and 25% reserve share retain nominal SUPRA amounts; SP alone covers shortfall" (Qwen R2-F3)
   - (5) now: "0.25% aggregate gap (rises to 1% in SP-empty windows when remaining 75% also burns); individual debtors face 1% per-trove shortfall" (Gemini R2-01, Qwen R2-F2)
   - (6) new: "Self-redemption allowed; behaves as partial debt repay + collateral withdraw with 1% fee" (DeepSeek R2-5)
3. **`liquidate()` u128-compute-cap-before-cast** (Gemini R2-02). 3 conversion sites (total_seize_supra / liq_supra / reserve_supra) now compute in u128, cap against u64-lifted bounds, cast to u64 last. Avoids pre-cap u64-cast overflow at extreme-low-price + large-trove edge.

**R2 items rejected (incorrect / would regress):**
- ChatGPT R2-3 pow10 bound "fragile" — math verified: 10^38 < 2^128-1, bound exact.
- ChatGPT R2-4 u128→u64 "silent truncation" — Move `as u64` aborts, not truncates; fee math always fits u64 anyway.
- ChatGPT R2-6 graceful-zero dust suggestion — would break supply-debt invariant.
- ChatGPT R2-7 `total_sp >= debt` — would REGRESS v0.2-audit critical fix (P=0 bug).
- DeepSeek R2-8 `total_debt` in reserve-redeem — misinterprets semantics (total_debt = Σ t.debt, not supply).

Tests: 16/16 pass (unchanged — no test behavior affected by R2 batch).

### Final-sweep submission checklist
- [ ] All R3 auditors re-submitted with R2-patched source (roster 4/8 captured at R2)

### R3 verdicts

- [x] **ChatGPT R3 (2026-04-23): 🟢 GREEN** — "v0.3.0 is ready to publish. R2→R3 diff minimal, correctly implemented, no regressions. u128 compute→cap→cast in `liquidate()` sound. 900s staleness materially improves oracle safety. All issues either fixed or intentionally documented." Nits: precision leakage in USD→SUPRA repeated conv (accepted design), `now_seconds()*1000` second-granularity (accepted), P-cliff + oracle liveness cliffs (WARNING-documented). Notable: ChatGPT was most critical at R2 (NEEDS FIX with 4 wrong proposals); R3 GREEN suggests R2 batch defused real concerns.
- [x] **Gemini R3 (2026-04-23): 🟢 GREEN** — "R2 diff minimal, precise, and correctly implements u128→cap→cast pattern. Effectively eliminates edge-case overflow while mathematically guaranteeing final values fit u64 bounds. Documentation accurately reflects consensus. No regressions or new attack vectors." Nit: L386-388 `total_seize_supra_u128 = (total_seize_supra as u128)` redundant after u64 cast — slight verbosity, Move compiler optimizes. Non-blocking.
- [x] **Qwen R3 (2026-04-23): 🟢 GREEN** — "R2 diff minimal and rigorously correct. 15-min staleness tightens front-running exposure. WARNING const documents deferred economic trade-offs accurately without breaking `test_warning_text_on_chain`. u128-compute-cap-cast refactoring definitively eliminates pre-cap integer overflow while preserving sequential bonus allocation. Regression sweep confirms zero side-effects on fee routing, SP accounting, cliff-guard invariants, trove debt bounds. 16/16 tests pass cleanly. No fresh attack surfaces." No nits.
- [x] **DeepSeek R3 (2026-04-23): 🟢 GREEN** — "R2 diff minimal, correctly implemented, regression test suite passes fully. No fresh attack surface or logic defects. u128-then-cap-then-cast in `liquidate()` correctly prevents overflow while preserving exact Move abort semantics."

### Gate status: **✅ CLEARED — 4/4 R3 GREEN**

All 4 R2-roster auditors (ChatGPT, Gemini, Qwen, DeepSeek) returned unconditional GREEN at R3. Per Darbitex Final SOP, gate to mainnet deploy is CLEARED.

## Post-mainnet audit (2026-04-23, Gemini 3.1 fresh session, source-only context)

Independent audit after mainnet deploy. Gemini 3.1 given only `sources/ONE.move` without R1-R3 history or WARNING const interpretation context.

Findings (10 items):

| Gemini 3.1 severity | Finding | Status |
|---|---|---|
| HIGH | Liquidation halts on strict `total_sp > debt` | ⚠ Known design — debated in R2 (ChatGPT R2-7 rejected). Strict `>` prevents P=0 bug fixed in v0.2 audit. Tradeoff: liquidation pauses if SP-empty (not protocol crash). |
| HIGH | 1% burn creates 0.25% supply/debt gap | ✅ Verbatim of WARNING (5). Pre-disclosed. |
| MEDIUM | P-cliff freezing | ✅ WARNING (1). |
| MEDIUM | u64 asymptotic overflow (decades-scale) | ✅ WARNING (2). |
| MEDIUM | Oracle dependency | ✅ WARNING header + LIMITATIONS. |
| LOW | CR<110% SP net loss | ✅ WARNING (4). |
| LOW | Genesis trove permanent lock post-null-auth | ✅ WARNING (3). |
| LOW | Self-redemption allowed | ✅ WARNING (6). |
| POSITIVE | Oracle-free `close_trove` escape hatch | Confirmed design feature. |

**0 new findings**. Every flagged item maps 1:1 to either a pre-disclosed WARNING const entry (items 1-6 embedded on-chain at line 53) or an R1-R3-locked design decision. Confirms WARNING const comprehensively captures all externally-audible risks.

Post-mainnet audit result: **DISCLOSURE ALIGNMENT CONFIRMED**. Nothing surfaced by fresh-context review that wasn't already documented on-chain at deploy time.

## Post-mainnet audit #2 (2026-04-23, Grok, source-only context)

Grok (xAI) previously unreachable at R1-R3; finally responded for post-mainnet review.

Grok output style differs from Gemini 3.1: narrative tutorial/overview rather than structured severity-tagged findings. No HIGH/MEDIUM/LOW labels applied.

**Strengths endorsed:**
- u256 intermediates in reward/settle math
- `MIN_P_THRESHOLD` cliff guard prevents SP wipeout
- Strict oracle checks (value>0, freshness, future-drift)
- Oracle-independent `close_trove` wind-down path
- Explicit 25% fee burn routing
- Comprehensive events
- Test-only isolated-math helpers
- No reentrancy surface (Move resource model)
- No external calls beyond oracle

**"Areas worth scrutiny"** (Grok phrasing — all map to prior fixes/disclosures):

| Grok item | Prior coverage |
|---|---|
| Liquidation math at edge prices | Gemini R2-02 u128-cap-before-cast fix |
| SP settle extreme sequences | R1 cliff guard + `test_liquidation_cliff_guard_aborts` |
| Self-redemption semantics | WARNING (6) |
| Total debt/SP accounting invariants | DeepSeek R2 verified, R2-1 false-alarm |
| BPS precision/rounding | Qwen R2-F3 accepted+doc |
| Genesis trove lock | WARNING (3) |
| Immutability verification | Confirmed via DEPLOYER_KEY_PROOF.md |

**Recommendations:** deploy testnet first (done), stress SP (cliff guard test exists), read WARNING (self-describing). **Improvements for forkers:** add health factor view, more visible oracle assumptions — nice-to-have, not blocking.

**0 new findings, no severity labels.** Confirms WARNING coverage is comprehensive per two independent post-mainnet fresh-context audits (Gemini 3.1 + Grok).

### Final-sweep submission checklist
- [ ] All 8 auditors re-submitted

### Findings log (R3)

### Final verdicts per auditor

| Auditor | R3 verdict | Notes |
|---|---|---|
| Gemini | | |
| Grok | | |
| Qwen | | |
| Kimi | | |
| DeepSeek | | |
| ChatGPT | | |
| Perplexity | | |
| Claude | | |

### Gate to mainnet

**Proceed only when ALL auditors report GREEN.** Most adversarial auditor's verdict = final blocker.

## Post-mainnet audit (future)

After mainnet deploy, one more audit pass for confirmation bias check + mainnet-specific concerns.
