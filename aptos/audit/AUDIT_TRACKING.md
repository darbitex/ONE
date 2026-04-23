# ONE Aptos — Audit Tracking Log

Tracks external AI auditor submissions and findings across R1 → R2 → R3.

**Pre-audit state (v0.1.0 at R0.2 patch, ready for R1 submission):**
- 19/19 unit tests pass
- Full source `sources/ONE.move` 572 lines
- Local Pyth interface stub in `deps/pyth/`
- Submission doc: `AUDIT_R1_SUBMISSION.md`

## Pre-audit screening

Two parallel pre-filter passes applied before R1 external submission:

**1. Self-audit (Claude in-session)** — `self_audit_R1_claude.md`
- 0 CRITICAL, 0 HIGH, 3 MEDIUM, 4 LOW, 5 INFO/NIT
- Surfaced: rename `supra→coll`, dead E_STALE, destroy_cap test gap, defensive staleness, post-scaling zero check
- All applied as **R0.1 patch** before pre-filter fusion

**2. Fusion pre-filter (OpenRouter free-tier, 5/8 models responded)** — `prefilter_*.md`
- Models: `gpt-oss-120b`, `tencent/hy3-preview`, `minimax-m2.5`, `inclusionai/ling-flash` + `nemotron-120b` empty. 3 rate-limited permanently on free pool.
- Real actionable surfaced: future-ts tolerance too loose (hy3), reserve-redeem inline doc gap (hy3), error slot 12 unused (minimax)
- Applied as **R0.2 patch**: future-ts 60s→5s, inline comment `redeem_from_reserve`, slot-12 comment
- False positives surfaced: ~9 (model misread Move semantics — assert direction, atomic aborts, cliff guard)
- No CRITICAL/HIGH real bug surfaced by any fusion model

**Signal-to-noise of fusion**: moderate. Free-tier models struggle with Move-specific semantics. Used as hygiene pre-filter only — NOT a substitute for R1 manual multi-LLM audit with strong reasoning models.

## Auditor roster

| # | Auditor | Platform |
|---|---|---|
| 1 | Gemini (web + 3.1 model) | Google |
| 2 | Grok | xAI |
| 3 | Qwen | Alibaba |
| 4 | Kimi | Moonshot |
| 5 | DeepSeek | — |
| 6 | ChatGPT | OpenAI |
| 7 | Perplexity | — |
| 8 | Claude (fresh session) | Anthropic |

## Round 1 submission checklist

- [ ] Gemini R1
- [ ] Grok R1
- [ ] Qwen R1
- [ ] Kimi R1
- [ ] DeepSeek R1
- [ ] ChatGPT R1
- [ ] Perplexity R1
- [ ] Claude fresh R1

## Focus areas for this audit (R1)

Per `AUDIT_R1_SUBMISSION.md`:

1. Pyth oracle integration in `price_8dec()` — scaling, validation, pull-based pattern
2. Resource-account immutability (`ResourceCap` + `destroy_cap`) — staging pattern, origin-only consume, capability drop safety
3. Move 2 language edges vs Move 1 Supra baseline
4. APT FA handling — `@0xa` convention, Coin-form migration assumption
5. Line-for-line baseline logic regressions (unlikely, but audit hygiene)

## Findings log (R1)

Format: `[SEVERITY] <auditor> — <location>: <finding> → <fix/no-fix rationale>`

**Gemini 3.1 R1 (2026-04-23) — verdict PROCEED (MINOR FIX BATCH):**
- [INFO] #1 immutability safety: confirmed secure. No action.
- [MEDIUM] #2 zero-debt trove close can burn 0-amount FA: `if (t.debt > 0)` guard. → **FIXED** in `close_impl`.
- [MEDIUM] #3 Pyth expo upper bound: `assert!(abs_e <= 18, E_EXPO_BOUND)`. → **FIXED**; E_EXPO_BOUND at slot 12.
- [LOW] #4 product_factor precision decay: no action.
- [NIT] #5 redundant timestamp check removal → **REJECTED** (defense-in-depth).
- [INFO] #6 redeem_from_reserve supply drift: confirmed correct. No action.

**Kimi R1 (2026-04-23) — verdict NEEDS FIX BATCH:**
- [CRIT→LOW] CRIT-1 u128 overflow in sp_settle: ❌ **FALSE POSITIVE**. Code uses `as u256` intermediates. Kimi missed the cast. Final `as u64` asymptotic concern already WARNING (2).
- [HIGH] HIGH-1 oracle VAA cherry-pick via stale window: valid. Pyth's own guidance ≤60s. → **FIXED**: STALENESS_SECS 900 → 60.
- [HIGH→SPEC] HIGH-2 liquidation CR<110% SP-priority alternative: already documented WARNING (3). Kimi's alternative = spec change. → **DEFER to R2 consensus**.
- [MED→SPEC] MED-1 scale factor vs cliff guard: explicit design choice. → **REJECTED**.
- [MED→SPEC] MED-2 zero-debt auto-close on redeem: design choice. → **REJECTED**.
- [INFO-1..4] documented / Kimi confirms FA dispatch safe (APT has `EAPT_NOT_DISPATCHABLE`), resource account safe.

**DeepSeek R1 (2026-04-23) — verdict NEEDS FIX BATCH:**
- [HIGH→PROCESS] F-01 oracle test gap: valid but substantial mocking infra needed. Defer to live integration.
- [MED] F-02 5s future-ts too tight: valid clock-drift concern. → **FIXED**: 5s → 30s.
- [MED→FALSE] F-03 SP-empty burn missing: ❌ **FALSE POSITIVE** (DeepSeek saw only excerpt; full source has `if (r.total_sp == 0) { burn }`).
- [LOW] F-04 precision degradation: known Liquity-P trade-off. Accept.
- [LOW] F-05 no event on destroy_cap: valid. → **FIXED**: `CapDestroyed` event added.
- [INFO] F-06/F-07: design choices / WARNING already covers.

**R1 fix batch applied (v0.1.0 → v0.1.1 internal):**
1. `close_impl` zero-debt guard (Gemini #2)
2. `E_EXPO_BOUND = 12` + `assert!(abs_e <= 18)` in price_8dec (Gemini #3)
3. `STALENESS_SECS 900 → 60` (Kimi HIGH-1)
4. Future-ts tolerance 5s → 30s (DeepSeek F-02 pushback on Gemini's tightening)
5. `CapDestroyed` event on destroy_cap (DeepSeek F-05)
6. WARNING text updated (15 min → 60 seconds)

19/19 tests still pass. **5 remaining R1 auditors pending**: Grok, Qwen, ChatGPT, Perplexity, Claude fresh.

**Qwen R1 (2026-04-23) — verdict NEEDS FIX BATCH (0 actionable):**
- [CRIT→FALSE] F-1 liquidation no explicit cap: ❌ **FALSE POSITIVE**. Full code has cascading caps (total_seize_coll → liq_coll → reserve_coll_amt → sp_coll residual). Qwen saw only snippet.
- [HIGH→FALSE] F-2 SP fee division-by-zero when total_sp=0: ❌ **FALSE POSITIVE**. `if (r.total_sp == 0) { burn }` branch guards division. Same pattern as DeepSeek F-03.
- [MED] F-3 raw magnitude bounds: over-restrictive given our new `abs_e <= 18` (Gemini fix). Math proves safe up to u128. → **REJECT**.
- [MED→SPEC] F-4 product_factor precision decay: known Liquity-P trade-off. Accept.
- [LOW] F-5 future-ts should be ≤2s: auditor range 2-60s; 30s mid-point defensible, Qwen's "malicious validator" concern moot (VAA requires Pyth guardian consensus). → **KEEP 30s**.
- [INFO] F-6 destroy_cap operational window: documented in DEPLOY.md.

Qwen confirmed: supply invariants, Move reentrancy, APT FA safety.

**Grok R1 (2026-04-23, full source via grok_submission.txt) — verdict NEEDS FIX BATCH:**
- [CRIT→SPEC] #1 liquidation split deviation at CR<110%: 3rd auditor on this area. Grok suggests prorate all 3 shares. Current design prioritizes liquidator incentive. → **DEFER R2 consensus**.
- [HIGH] #2 oracle brittleness — several sub-items, all spec-accepted (expo revert = safe, no conf = intentional, 30s tolerance settled). No fix.
- [HIGH] #3 u128→u64 long-term — WARNING (2).
- [MED] #4 fee dust — WARNING covers.
- [MED] #5 immutability sound — confirms. Suggests view confirming cap gone. → **FIXED**: `is_sealed()` view added.
- [LOW] #6 reentrancy low-risk — confirms.
- [NIT] #8 `LIQ_SP_DEPOSITOR_BPS` unused — ✅ **FIXED**: removed (SP gets remainder).

**Claude fresh R1 (2026-04-23, submission doc only, no source) — verdict NOT READY:**
Scope caveat: Claude explicitly called out partial source as blocker (H-04). Only reviewed excerpts shown in submission doc.
- [HIGH] H-01 Pyth confidence interval not checked: real concern, prod DeFi losses cited. → **FIXED**: `MAX_CONF_BPS=200` (2%) + assert in `price_8dec`.
- [HIGH] H-02 zero oracle unit tests: valid, defer (Pyth mocking needs substantial Move test VM work).
- [HIGH→FALSE] H-03 STALENESS_SECS=900s too wide: ❌ Claude saw old submission doc (pre-Kimi fix). Already reduced to 60s.
- [HIGH] H-04 no full source submitted: process critique. Future submissions use grok_submission.txt-style full-source pastes.
- [MED] M-01 VAA externalized: design choice, accept.
- [MED] M-02 MIN_DEBT=1 ONE too low: spec decision (matches Supra history). Keep.
- [MED] M-03 SP cliff no recovery via reset-on-empty: interesting Liquity V2 pattern, ~3-line change. → **DEFER R2 consensus**.
- [MED] M-04 Pyth feed de-registration: tail risk, document.
- [MED] M-05 close deficit explanatory view: ✅ **FIXED**: `close_cost(addr)` view added.
- [MED] M-06 FA dispatch forward risk: Kimi confirmed `EAPT_NOT_DISPATCHABLE`. Document.

**Cumulative R1 fix batch additions (post Grok+Claude):**
- Removed unused `LIQ_SP_DEPOSITOR_BPS` (Grok NIT)
- Added `#[view] is_sealed(): bool` (Grok MED-5)
- Added `MAX_CONF_BPS = 200` + `E_PRICE_UNCERTAIN = 19` + conf/raw ratio assert in price_8dec (Claude H-01)
- Added `#[view] close_cost(addr): u64` (Claude M-05)

Tests still 19/19. **6/8 R1 auditors done** (Gemini, Kimi, DeepSeek, Qwen, Grok, Claude fresh). Remaining: ChatGPT, Perplexity.

**R2 spec discussions to open** (multi-auditor concur needed):
- Liquidation SP-priority vs current liquidator-incentive priority (Kimi HIGH-2, Qwen F-1, Grok CRIT, ChatGPT #2)
- SP cliff reset-on-empty (Claude M-04 — APPLIED, pending R2 verification)
- MIN_DEBT raise from 1 to 100+ ONE (Claude M-03)

**ChatGPT R1 (2026-04-23) — verdict NEEDS FIX BATCH:**
- [CRIT→NO-CHANGE] #1 `total_sp > debt` → `>=`: technically redundant with cliff guard (same case aborts either way via E_P_CLIFF). Keep strict `>` for clearer error attribution. Same reject as Supra R2.
- [CRIT→SPEC] #2 SP griefing via low-CR liquidation: 4th auditor flagging this area. Spec-accepted; WARNING (3) updated post-Claude. Defer R2.
- [HIGH] #3 expo truncation at high abs_e: already bounded (≤18, Gemini). APT/USD standard expo=-8 = no truncation. Reject tighter.
- [HIGH] #4 liquidation rounding leakage: sub-cent, accepted (multiple auditors concur).
- [HIGH] #5 reward_index u128 overflow unbounded: asymptotic (3.4e22 fee calls needed). Documented WARNING (2).
- [MED] #6 sp_settle saturation silent loss: valid transparency add. → **FIXED**: `RewardSaturated` event emitted on truncation.
- [MED] #7 redeem dust threshold abort: UI concern (correct one_amt computed off-chain). Reject.
- [MED] #8 last-updater-wins oracle: inherent Pyth design; guardian consensus limits attack surface.
- [MED] #9 close_impl 1% deficit: WARNING (4) covers.
- [LOW/INFO] #10-12 pow10 gas, reentrancy confirmation, immutability solid.

**Final R1 fix batch additions (post-ChatGPT):**
- `RewardSaturated` event in sp_settle (ChatGPT #6)

**R1 ROSTER COMPLETE: 7/8 auditors** (Gemini, Kimi, DeepSeek, Qwen, Grok, Claude-fresh, ChatGPT). Perplexity skipped.

**Cumulative R1 fix batch:**
1. close_impl zero-debt guard (Gemini #2)
2. E_EXPO_BOUND + abs_e ≤18 assert (Gemini #3)
3. STALENESS_SECS 900 → 60 (Kimi HIGH-1, Pyth best practice)
4. Future-ts tolerance 60→30→10s (DeepSeek/Gemini/Claude consensus)
5. CapDestroyed event (DeepSeek F-05)
6. is_sealed() view (Grok #5)
7. Removed unused LIQ_SP_DEPOSITOR_BPS (Grok NIT)
8. MAX_CONF_BPS = 200 + E_PRICE_UNCERTAIN + conf check (Claude H-01)
9. close_cost(addr) view (Claude M-05 partial)
10. Atomic `*_pyth` wrapper entries × 4 (Claude M-01)
11. product_factor reset-on-empty in sp_deposit (Claude M-04, Liquity V2 pattern)
12. Saturate pending rewards at u64::MAX (Claude M-06)
13. WARNING (3) accurate wording at extreme CR (Claude M-07)
14. trove_health(addr) view (Claude L-04)
15. RewardSaturated event (ChatGPT #6)

**R1 false positives (no action, auditor error):**
- Kimi CRIT-1 u128 overflow (missed `as u256` cast)
- DeepSeek F-03 SP-empty burn (read excerpt, not full source)
- Qwen F-1/F-2 (same — read excerpt)
- Claude fresh (markdown-only) H-03 staleness 900s (saw stale doc)

**R1 rejected as spec-accepted (docs/WARNING cover or design choice):**
- Kimi HIGH-2, Qwen F-4, Grok CRIT #1, ChatGPT #2: liquidation SP-priority
- Kimi MED-1 scale factor mechanism (complexity trade-off)
- Kimi MED-2 auto-close zero-debt (owner-explicit preferred)
- Claude M-02 MIN_DEBT raise
- ChatGPT #1 total_sp >= debt (cliff guard redundant, strict > keeps error clarity)

Tests: 19/19 pass. Source 668 lines.

---

## Round 2 (after R1 fix batch)

### Fix batch R1 applied
(tbd)

### Findings log (R2)
(tbd)

---

## Round 3 (final gate)

### R3 verdicts
- [ ] Gemini R3
- [ ] Grok R3
- [ ] Qwen R3
- [ ] Kimi R3
- [ ] DeepSeek R3
- [ ] ChatGPT R3
- [ ] Perplexity R3
- [ ] Claude R3

### Gate to mainnet
All roster auditors GREEN → proceed. Most adversarial auditor's verdict = final blocker.

## Supra baseline cross-reference

For items that are line-for-line Supra R3:
- Ask auditor to mark as "baseline-carried" rather than re-flagging
- Focus critique on the 6 delta areas above
- R3 Supra trail: https://github.com/darbitex/ONE (Supra version)
