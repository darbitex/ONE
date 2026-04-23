# minimax  — minimax/minimax-m2.5:free

I'll review this Move stablecoin contract with an adversarial lens, focusing on the areas specified.

**Preliminary Scan:** The contract is ~570 lines, implements a Liquity-style stability pool mechanism with Pyth oracle integration. Let me identify concrete issues.

---

### Finding 1: Fee Truncation Allows Zero-Fee Minting

**Severity:** MEDIUM  
**Location:** `sources/ONE.move:298` (open_impl)  
**Issue:** Fee calculation `(((debt as u128) * (FEE_BPS as u128)) / 10000) as u64` truncates to zero for debt < 10000 (0.01 ONE = 1e6 Wei).  
**Impact:** User can open trove with debt=1 (minimum MIN_DEBT=1e8), pay zero fee. This bypasses the 1% mint fee for small positions and the 25% burn portion that funds supply deflation.  
**Recommendation:** Add assertion: `assert!(fee > 0, E_FEE_ZERO)` or require `debt >= 10000` in open_impl.  
**Confidence:** HIGH

---

### Finding 2: Missing Balance Check in redeem_impl

**Severity:** HIGH  
**Location:** `sources/ONE.move:349` (redeem_impl)  
**Issue:** `primary_fungible_store::withdraw(user, r.metadata, one_amt)` is called without verifying caller holds sufficient ONE balance. If balance < one_amt, call aborts with generic FA error rather than explicit "E_INSUFFICIENT_BALANCE".  
**Impact:** User receives opaque error; differentiates poorly from other failure modes (target missing, insufficient collateral).  
**Recommendation:** Add: `assert!(primary_fungible_store::balance(user, r.metadata) >= one_amt, E_INSUFFICIENT_BALANCE)` before withdraw.  
**Confidence:** HIGH

---

### Finding 3: Missing Balance Check in close_trove

**Severity:** HIGH  
**Location:** `sources/ONE.move:336` (close_impl)  
**Issue:** Same as Finding 2. Burns `t.debt` via `primary_fungible_store::withdraw(user, r.metadata, t.debt)` without pre-check.  
**Impact:** User attempting to close trove without sufficient ONE balance gets generic FA error.  
**Recommendation:** Add balance assertion before withdraw.  
**Confidence:** HIGH

---

### Finding 4: Liquidation Overflow Edge Case

**Severity:** MEDIUM  
**Location:** `sources/ONE.move:416`  
**Issue:** `total_seize_u128 = total_seize_usd * 100_000_000 / price` performs u128 multiplication. While debt max (2^64-1) * 1.1 * 1e8 fits in u128, there's no explicit overflow guard.  
**Impact:** If price is extremely low (near 1), multiplication could theoretically approach u128 bounds.  
**Recommendation:** Add comment documenting the bound, or split multiplication: `(total_seize_usd / price) * 100_000_000 + (total_seize_usd % price) * 100_000_000 / price`.  
**Confidence:** MEDIUM

---

### Finding 5: SP-Empty Fee Routing Burns 75% Intentionally — Documentation Accurate

**Severity:** INFO  
**Location:** `sources/ONE.move:270` (route_fee_fa)  
**Issue:** When `r.total_sp == 0`, entire fee (including the 75% intended for SP depositors) is burned.  
**Impact:** This matches documented limitation #4 ("rises to 1% in SP-empty windows"). Correct behavior per spec, but worth flagging for auditors.  
**Recommendation:** None — working as designed.  
**Confidence:** HIGH

---

### Finding 6: Oracle Staleness Check Redundancy

**Severity:** LOW  
**Location:** `sources/ONE.move:248-249`  
**Issue:** `pyth::get_price_no_older_than(id, STALENESS_SECS)` already enforces staleness. The subsequent manual checks `ts + STALENESS_SECS >= now` and `ts <= now + 60` are redundant but provide defense-in-depth.  
**Impact:** Minor gas inefficiency (extra timestamp fetches).  
**Recommendation:** Accept as defense-in-depth or remove manual checks to save gas.  
**Confidence:** HIGH

---

### Finding 7: Resource Account Immutability — Window Between Init and Destroy

**Severity:** MEDIUM  
**Location:** `sources/ONE.move:222-227` (init_module) + `destroy_cap`  
**Issue:** Between publish and `destroy_cap` call, `ResourceCap { cap }` is stored at `@ONE`. Origin can call `destroy_cap` at any time, but if compromised in this window, they could destroy the cap early (preventing future legitimate destroy) or front-run the intended destroy transaction.  
**Impact:** Origin key exposure between publish and destroy is a known risk, but no actor can extract the cap to sign arbitrary txns (cap is consumed into ResourceCap storage).  
**Recommendation:** Document that destroy_cap should be called immediately after publish in deployment scripts.  
**Confidence:** HIGH

---

### Finding 8: No Error Code 12 Defined

**Severity:** INFO  
**Location:** `sources/ONE.move:56-73`  
**Issue:** Error codes jump from 11 (E_PRICE_ZERO) to 13 (E_DECIMAL_OVERFLOW). Code 12 is unused.  
**Impact:** None.  
**Recommendation:** None.  
**Confidence:** HIGH

---

### Finding 9: Test Coverage Gap — Oracle-Dependent Paths

**Severity:** MEDIUM  
**Location:** `tests/ONE_tests.move` (not provided in full, but 19 tests listed)  
**Issue:** open_trove, redeem, liquidate, redeem_from_reserve all depend on `price_8dec()` calling real Pyth. Unit tests cannot exercise these paths.  
**Impact:** Critical invariants (MCR enforcement, liquidation threshold, redemption math) not verified in unit tests. Relies on integration testing.  
**Recommendation:** Document that integration tests must cover: (a) open_trove at exactly MCR=200%, (b) liquidate at CR=149%, (c) redeem leaving dust debt=MIN_DEBT-1 (should abort), (d) redeem leaving debt=0 (should succeed).  
**Confidence:** HIGH

---

### Finding 10: sp_settle Uses u256 for Intermediate — Good

**Severity:** INFO  
**Location:** `sources/ONE.move:283-285`  
**Issue:** None. The code correctly uses u256 for `(r.reward_index_one - snap_i_one) * initial` before dividing, preventing overflow in reward calculation.  
**Impact:** Good practice.  
**Recommendation:** None.  
**Confidence:** HIGH

---

### Finding 11: Liquidation Cliff Guard — Correct Implementation

**Severity:** INFO  
**Location:** `sources/ONE.move:404`  
**Issue:** None. `assert!(new_p >= MIN_P_THRESHOLD, E_P_CLIFF)` correctly aborts liquidations that would corrupt P. Matches documented limitation #1.  
**Impact:** Working as designed.  
**Confidence:** HIGH

---

### Finding 12: redeem_from_reserve Hard Assertion — No Partial Fill

**Severity:** LOW  
**Location:** `sources/ONE.move:379`  
**Issue:** `assert!(fungible_asset::balance(r.reserve_coll) >= coll_out, E_INSUFFICIENT_RESERVE)` aborts entirely if reserve insufficient.  
**Impact:** User cannot partially redeem from reserve. Matches spec but may surprise users.  
**Recommendation:** Consider returning partial amount or documenting explicitly.  
**Confidence:** HIGH

---

### Finding 13: Self-Redemption Allowed

**Severity:** INFO  
**Location:** `redeem_impl` (no check for `signer::address_of(user) != target`)  
**Issue:** User can redeem against their own trove.  
**Impact:** Documented as limitation #5. Works as partial repay + collateral withdraw + 1% fee.  
**Confidence:** HIGH

---

### Finding 14: Double-Call Protection on destroy_cap

**Severity:** INFO  
**Location:** `sources/ONE.move:232-233`  
**Issue:** `assert!(exists<ResourceCap>(@ONE), E_CAP_GONE)` prevents double-call.  
**Impact:** Correct.  
**Confidence:** HIGH

---

### Finding 15: Missing E_INSUFFICIENT_BALANCE Error Code

**Severity:** LOW  
**Location:** Error constants  
**Issue:** No error code for "caller has insufficient ONE balance" — would need to add to error constants if fixing Finding 2/3.  
**Impact:** Requires new error code addition.  
**Confidence:** HIGH

---

## Verdict

**NEEDS-FIX**

The contract is well-designed with good defensive programming (cliff guard, oracle redundancy, u256 intermediates). However, the missing balance checks in `redeem_impl` and `close_impl` (Findings 2, 3) are HIGH severity — they cause opaque error messages in common failure scenarios. The fee truncation issue (Finding 2) is a MEDIUM that allows fee bypass on small positions.

All other findings are informational or document known limitations correctly implemented.

**Required fixes before formal multi-LLM audit:**
1. Add balance pre-checks in `redeem_impl` and `close_impl` (HIGH)
2. Add fee > 0 assertion or minimum debt check in `open_impl` (MEDIUM)

---
tokens: in=12791 out=4292 dt=92.5s
