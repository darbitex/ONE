# ONE Aptos v0.1.0 — Self-Audit R1 (Claude Opus 4.7, parallel auditor)

**Auditor:** Claude (in-session, this conversation's agent)
**Scope:** Full source `sources/ONE.move` (580 lines) + Move.toml + local Pyth stub (`deps/pyth/`)
**Date:** 2026-04-23
**Context:** Fresh-eyes full audit, NOT delta-only. Treat as independent Round-1 input parallel to external AI auditors.

---

## Executive summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 3 |
| LOW | 4 |
| INFO / NIT | 5 |

**Verdict preliminary: NEEDS MINOR FIX BATCH** before R2, blocking items are nomenclature / test-coverage / defensive (not security-critical). Nothing blocks deploy conceptually, but audit-hygiene items should be addressed before external reviewers see it to reduce noise.

---

## MEDIUM

### M-1. Registry field names still use `supra` suffix — not on-chain bug but audit readability

**Location:** `struct Registry` lines 75-97; Trove/SP/events similarly.

**Issue:** Fields like `sp_supra_pool`, `sp_supra_extend`, `reserve_supra`, `reward_index_supra` hold APT (not SUPRA) on Aptos. `supra_amt` param name in `open_trove`, `add_collateral`, `redeem`, `redeem_from_reserve`, `liquidate` etc.

**Impact:** External auditors will flag this as confusing. Not a bug (code behaves correctly, it's APT-in-APT-out), but it creates audit friction, and a future reader looking at on-chain Registry might think there's a SUPRA leg somewhere.

**Recommendation:** Rename in source before R2 submission:
- `sp_supra_pool` → `sp_coll_pool` (collateral pool for SP)
- `reserve_supra` → `reserve_coll`
- `reward_index_supra` → `reward_index_coll`
- `supra_amt` param → `coll_amt`
- `sp_supra_absorbed` in test helper → `sp_coll_absorbed`

Keeping "coll" abstraction makes the port cleaner for future chains too. Or explicitly `_apt` if we commit to APT-only.

**Confidence:** High (style), but bug risk = 0.

### M-2. `E_STALE` (code 4) is dead — declared but never asserted in Aptos fork

**Location:** Line 45.

**Issue:** In Supra version, `E_STALE` was used by the staleness check inside `price_8dec()`. On Aptos, `pyth::get_price_no_older_than` enforces staleness internally (aborts with Pyth's own error code), so we never use `E_STALE`.

**Impact:** Dead code confuses auditors. Not a bug.

**Recommendation:** Either:
(a) Remove `E_STALE` constant (error codes don't need to be contiguous),
(b) Add a comment `// reserved — Pyth handles staleness` to preserve numbering,
(c) Add explicit defence-in-depth staleness check:
```move
let ts = price::get_timestamp(&p);
let now = timestamp::now_seconds();
assert!(ts + STALENESS_SECS >= now, E_STALE);
```
Option (c) adds belt-and-suspenders: if Pyth's `get_price_no_older_than` misbehaves or is re-semanticized in a future framework update, our own check still catches stale prices.

**Recommendation:** (c) for defensive depth. Trivial.

**Confidence:** High.

### M-3. Test suite does NOT exercise `destroy_cap` or `ResourceCap` staging

**Location:** `tests/ONE_tests.move` (entire file).

**Issue:** All 16 existing tests use `init_module_for_test` which calls `init_module_inner` directly, **bypassing** `init_module` and the `ResourceCap` staging logic. No test:
- Verifies `destroy_cap` aborts with `E_NOT_ORIGIN` when called by non-origin
- Verifies `destroy_cap` aborts with `E_CAP_GONE` on second call
- Exercises the `retrieve_resource_account_cap` → `option::destroy_some` drop path

**Impact:** The NEW immutability mechanism (the main audit-focus delta from Supra) has zero automated coverage. A bug in `destroy_cap` gating would only surface in mainnet, post-deploy, when too late.

**Recommendation:** Add three tests before R2:
1. `test_destroy_cap_non_origin_aborts` — build `ResourceCap` via test helper, call `destroy_cap` as non-origin, expect `E_NOT_ORIGIN`.
2. `test_destroy_cap_double_call_aborts` — run destroy_cap twice, second must hit `E_CAP_GONE`.
3. `test_destroy_cap_consumes_resource` — verify `exists<ResourceCap>(@ONE)` goes true → false.

This requires a `#[test_only]` helper like `test_stash_resource_cap(sc: SignerCapability)` or a mock SignerCapability constructor. May need `account::create_signer_for_test` + resource_account test utilities.

**Confidence:** High.

---

## LOW

### L-1. `redeem_impl` / `redeem_from_reserve` can abort on u64 cast in extreme low-price regime

**Location:** `redeem_impl` line 310, `redeem_from_reserve` line 363.

```move
let supra_out = (((net as u128) * 100_000_000 / price) as u64);
```

**Issue:** If APT crashes catastrophically (e.g., 1000x → price_8dec = 1), and `net` is large (e.g., 1.84e8 ONE redeemed at $0.001/APT), the u128 intermediate exceeds u64 max → `as u64` aborts. Bricks redeem path for that tx.

**Impact:** Edge-case DoS under extreme crash. User can retry with smaller `net`. In practice unreachable for normal operation.

**Note:** Same as Supra R3 baseline. Addressed in `liquidate` (u128-cap-before-cast applied there via R2 batch) but NOT in redeem paths. The asymmetry is intentional — liquidate has a natural cap (target's `coll`), redeem doesn't.

**Recommendation:** Accept as spec-level limitation. Document in WARNING const: "extreme price regimes may cause transient redeem path aborts until smaller amounts are used."

**Confidence:** High (analysis), low (severity — truly edge).

### L-2. `smart_table::remove` during liquidation — state ordering risk

**Location:** `liquidate` lines 406-419.

**Issue:** Order of operations:
1. Line 406: `smart_table::remove(&mut r.troves, target)` — trove removed
2. Line 407: `r.total_debt -= debt`
3. Line 410: `fungible_asset::withdraw(&sp_signer, r.sp_pool, debt)` — burn sp_pool ONE
4. Line 411: `fungible_asset::burn(burn_ref, burn_fa)`
5. Line 414: compute new_p; assert `new_p >= MIN_P_THRESHOLD` — **can abort here**
6. Lines 416-419: state commit
7. Lines 421-427: FA movements for liquidator/reserve/SP

If the assertion at line 415 (cliff guard) fires, the tx aborts and all state is rolled back by Move VM — including the `smart_table::remove` at line 406. So logically safe, but the code reads as though state is mutated before the critical assertion.

**Impact:** No actual bug (Move aborts roll back). But readability: auditor may think "trove removed but cliff not yet checked" is a lost-trove scenario.

**Recommendation:** Reorder to compute cliff guard FIRST, then mutate:
```move
let total_before = r.total_sp;
let new_p = r.product_factor * ((total_before - debt) as u128) / (total_before as u128);
assert!(new_p >= MIN_P_THRESHOLD, E_P_CLIFF);

smart_table::remove(&mut r.troves, target);
// ... etc
```
Move tx abort semantics make this purely cosmetic, but clearer for reviewers.

**Confidence:** High (no bug, style).

### L-3. `price_8dec()` could silently return 0 if `abs_e > 38`

**Location:** Line 181: `raw / pow10(abs_e - 8)`.

**Issue:** `pow10(n)` asserts `n <= 38` (line 188). So `pow10(abs_e - 8)` requires `abs_e - 8 <= 38`, i.e., `abs_e <= 46`. If Pyth ever returns expo with magnitude 47+ (`10^-47`), pow10 aborts with E_DECIMAL_OVERFLOW.

For realistic Pyth feeds, expo is typically -8 to -12. `abs_e` well under 38. Safe in practice.

But: `abs_e = 38` → `pow10(30) = 1e30`. `raw / 1e30` — if raw < 1e30 (which it always is since raw is u128 cast of i64 positive, max ~1e18), result = 0.

Then `price_8dec() = 0`. Callers:
- `open_impl` line 260: `coll_usd * 10000 >= MCR_BPS * new_debt` — coll_usd = new_coll * 0 / 1e8 = 0. `0 >= MCR_BPS * new_debt` = false (since new_debt > 0). Assertion fires → E_COLLATERAL.
- `redeem_impl` line 310: `(net as u128) * 1e8 / 0` → divide by zero abort.
- `liquidate` line 394: same divide by zero.

So if price_8dec returns 0 due to abs_e=46 case, redeem/liquidate abort with arithmetic, not our E_PRICE_ZERO. We check `raw > 0` but not the post-scaling result.

**Recommendation:** Add post-scaling zero check:
```move
let result = if (abs_e >= 8) raw / pow10(abs_e - 8) else raw * pow10(8 - abs_e);
assert!(result > 0, E_PRICE_ZERO);
result
```
Safety belt against Pyth feed with ultra-low raw value + high-magnitude expo combination.

**Confidence:** Medium (edge case).

### L-4. No explicit check that `@origin` matches in `init_module`

**Location:** Line 112: `let cap = resource_account::retrieve_resource_account_cap(resource, @origin);`

**Issue:** The call will abort inside aptos_framework if `@origin` at compile-time doesn't match the ORIGIN that actually created the resource account at deploy time. So Move.toml `origin = "0x0047a3e1..."` must match the actual deployer.

If someone forks ONE and deploys with a different origin, they MUST update Move.toml's `origin` address to their own, otherwise `retrieve_resource_account_cap` will abort and publish will fail. Forker may be confused by cryptic framework abort.

**Recommendation:** Document clearly in DEPLOY.md: "Move.toml `origin` = the address that will sign `create_resource_account_and_publish_package`." No code change needed.

**Confidence:** High.

---

## INFO / NIT

### I-1. `SP` struct field named `snapshot_index_supra` — same supra-vestige as M-1.
### I-2. `add_collateral` re-fetches `apt_metadata` on every call — minor gas, not fix.
### I-3. FA symbol = "1" (single char). Some older wallets may display oddly. Spec-locked, acceptable.
### I-4. `E_STALE_FUTURE`, `E_STALE` (Supra R2 fixes) — not applied here because Pyth handles internally. Confirm this was intentional deletion.
### I-5. Move.toml `upgrade_policy = "compatible"` — correct (deps force it). Functional immutability = resource account SignerCapability destroyed. Matches Supra precedent.

---

## Cross-reference vs Supra R3 baseline

Items that carried over from Supra R3 without modification:
- Liquity-P math (product_factor, reward_index_one, reward_index_supra) — reviewed in Supra R1-R3.
- 25/50/25 liquidation split — reviewed.
- 1% fee with 25% burn — reviewed.
- Post-redeem dust invariant — from Supra R1 fix batch.
- u128 compute-then-cap-then-cast in `liquidate` — from Supra R2 fix batch.
- MIN_P_THRESHOLD = 1e9 cliff guard — from Supra R1 fix batch.
- 15-min oracle staleness (via Pyth's `get_price_no_older_than` param) — Supra R2 reduced to 900s.
- WARNING const with 6 limitations — Supra R2.

**Regression risk from port:** I did not identify any logic-level regression from Supra R3. The framework namespace swap is mechanical.

---

## Recommended fix batch pre-R2 submission

**Security-relevant (apply before external audit):**
1. **L-3 post-scaling zero check** in `price_8dec()` (+ 2 lines, trivial).
2. **M-2 (c) defensive staleness check** in `price_8dec()` using `price::get_timestamp` + `timestamp::now_seconds` + `E_STALE` (belt-and-suspenders).
3. **M-3 add 3 destroy_cap tests** (non-origin, double-call, consumes resource).

**Audit-readability (apply before external audit):**
4. **M-1 rename `supra` → `coll`** in Registry fields, params, test helper params, field nomenclature.

**Optional polish:**
5. **L-2 reorder liquidate** to move cliff assert before smart_table::remove.
6. **L-4 document `@origin` requirement** in DEPLOY.md.

Items 1-4 should be committed as R0.1 patch + re-tested (16→19 tests) before sending R1 submission to external auditors. This avoids wasting auditor attention on already-known items.

---

## Post-audit note to self

I (Claude, this session's agent) am NOT independent of the code author (also me). My self-audit has systematic bias:
- I can't cross-check the "why did I write this?" for every line — my reasoning may be circular.
- Patterns I consider "obviously fine" may hide bugs external auditors catch.

The 6 items above are the ones I can identify with non-circular reasoning. External auditors (Gemini/Grok/Qwen/Kimi/DeepSeek/ChatGPT/Perplexity/other-Claude-fresh) are essential, not optional. This self-audit is **supplementary only**, never a substitute.

User is right to insist on strict multi-LLM SOP.
