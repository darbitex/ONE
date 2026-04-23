# hy3  — tencent/hy3-preview:free

- **Severity**: CRITICAL
- **Location**: `liquidate` function (seizure math)
- **Issue**: Liquidation splits `total_seize_coll` (capped at actual collateral) into `liq_coll`, `reserve_coll_amt`, and `sp_coll`. However, `liq_coll` and `reserve_coll_amt` are computed from USD shares (`liq_share_usd`, `reserve_share_usd`) without capping to the remaining seized amount. If collateral value is insufficient (CR < 110%), `liq_coll + reserve_coll_amt` can exceed `total_seize_coll`, causing `sp_coll = total_seize_coll - liq_coll - reserve_coll_amt` to underflow (u64 wrap or abort depending on checker). The protocol acknowledges SP loss but the code does not safely handle the split arithmetic.
- **Impact**: Liquidation can abort or corrupt state when trove CR is between 100% and 110%, preventing liquidations or causing arithmetic panics.
- **Recommendation**: Cap `liq_coll` and `reserve_coll_amt` cumulatively to `total_seize_coll` before computing `sp_coll`. Explicitly handle shortfall: SP absorbs remainder, liquidator/reserve get their capped shares.
- **Confidence**: HIGH

- **Severity**: CRITICAL
- **Location**: `sp_settle` function (balance update)
- **Issue**: `new_balance` is computed as `(initial * product_factor) / snap_p`. However, `initial_balance` is a u64, `product_factor` and `snap_p` are u128. The intermediate cast to u256 and back to u64 can silently truncate if the result exceeds `u64::MAX` (18.4e18). Under sustained activity with P decay, `product_factor / snap_p` can be < 1, but if `initial_balance` is large and P has appreciated, the result can overflow u64. There is no overflow check on the u256→u64 cast.
- **Impact**: SP depositor balance can silently wrap/truncate, leading to incorrect withdrawals, reward theft, or protocol insolvency.
- **Recommendation**: Enforce that `new_balance` fits in u64 with an assert, or store `initial_balance` as u128. Given the warning mentions asymptotic u64 overflow over decades, add an explicit guard now.
- **Confidence**: HIGH

- **Severity**: CRITICAL
- **Location**: `route_fee_fa` function (reward index update)
- **Issue**: `reward_index_one` update: `r.reward_index_one + (sp_amt as u128) * r.product_factor / (r.total_sp as u128)`. `reward_index_one` is u128. If `sp_amt * product_factor` exceeds u128 max (~3.4e38), this silently wraps. `sp_amt` is u64 (max 1.8e19) and `product_factor` is up to 1e18, product up to ~1.8e37 — technically safe. However, if `product_factor` is ever close to PRECISION and `sp_amt` is large, repeated additions can push `reward_index_one` beyond u128 max over many cycles. No overflow guard exists.
- **Impact**: Reward index wraps → SP reward calculations become garbage → depositors lose funds or can drain pool.
- **Recommendation**: Add `assert!(result >= r.reward_index_one, E_OVERFLOW)` or use checked math. Consider resetting/checkpointing indices.
- **Confidence**: MEDIUM

- **Severity**: HIGH
- **Location**: `redeem_impl` function (collateral output bounds)
- **Issue**: `coll_out = ((net * 100_000_000) / price)` cast to u64. If `price` is very low (extreme APT crash), the result can exceed `u64::MAX` (1.8e19). The cast truncates silently. The subsequent `assert!(t.collateral >= coll_out)` may pass incorrectly or the subtraction may underflow.
- **Impact**: Redeem can mint ONE and seize wrong collateral amount, or abort unexpectedly during market stress when users need exit most.
- **Recommendation**: Check that `coll_out_u128 <= u64::MAX` before casting. Split large redeems or abort with a clear error.
- **Confidence**: HIGH

- **Severity**: HIGH
- **Location**: `price_8dec` function (staleness check)
- **Issue**: `assert!(ts <= now + 60, E_STALE)` allows prices from the *future* up to 60 seconds. Pyth timestamps can be slightly ahead of chain time. This is intentional belt-and-suspenders, but it means a malicious or buggy Pyth feed with a future timestamp will be accepted, potentially manipulating oracle price.
- **Impact**: Attacker with Pyth feed manipulation capability can use future timestamps to bypass staleness checks and push favorable prices.
- **Recommendation**: Remove or tighten the future tolerance. At minimum, document this as a known risk. Consider `ts <= now` or small fixed tolerance (1-2 seconds).
- **Confidence**: MEDIUM

- **Severity**: HIGH
- **Location**: `init_module_inner` (object creation)
- **Issue**: Multiple `object::create_object(da)` calls use `@ONE` deployer address (`da`) to create objects for fee pool, SP pool, etc. If `destroy_cap` is not called, these objects are extendable by `@ONE` signer. After `destroy_cap`, the `ExtendRef`s remain in `Registry`. While no signer exists to call `generate_signer_for_extending` *unless* an extend-ref-capable path exists, the `ExtendRef` itself is a capability. If any future Move feature or module can use an `ExtendRef` without a signer, these pools could be extended/migrated. Currently safe, but fragile.
- **Impact**: Future Aptos features might allow extending objects without signer, breaking immutability.
- **Recommendation**: After `destroy_cap`, consider burning the `ExtendRef`s (if possible) or document this as accepted risk.
- **Confidence**: LOW (depends on future VM changes)

- **Severity**: MEDIUM
- **Location**: `open_impl` (existing trove top-up)
- **Issue**: `open_trove` with `coll_amt = 0` and existing trove allows debt-only minting without adding collateral. This can instantly make a healthy trove underwater if MCR is not rechecked *after* the new debt is added (it is checked: `new_coll` and `new_debt` are used). However, the fee is minted *before* the trove is updated in `smart_table`. A reentrancy is impossible in Move, but the order means the fee is minted based on `debt` but the trove update happens after. Not a bug, but the fee is sent to user while trove update is delayed.
- **Impact**: Minor: fee accounting is correct, but ordering is non-standard.
- **Recommendation**: Update trove state before minting for clarity.
- **Confidence**: LOW

- **Severity**: MEDIUM
- **Location**: `redeem_from_reserve` (supply invariant)
- **Issue**: `redeem_from_reserve` reduces supply by `net + fee_burn` but does not touch `total_debt`. This is correct per spec (reserve is excess collateral, not tied to troves). However, if reserve is drained and later troves are liquidated, the reserve can go negative? No, it's a store. But the invariant `circulating_supply <= total_debt` can be broken if reserve redemption outpaces debt, since supply drops but debt remains. This is by design (reserve is separate), but it means the protocol can have supply < total_debt permanently, which is fine.
- **Impact**: None, by design. But worth documenting clearly.
- **Recommendation**: Add a comment in code that reserve redemption does not affect `total_debt`.
- **Confidence**: HIGH

- **Severity**: MEDIUM
- **Location**: `liquidate` (target remainder handling)
- **Issue**: After liquidation, `target_remainder` is sent back to `target` from `r.treasury`. However, the trove is already removed. If the liquidation leaves dust collateral (< MIN_DEBT worth), the target cannot reopen without fresh collateral. This is acceptable, but the remainder is sent unconditionally.
- **Impact**: None critical.
- **Recommendation**: Consider if remainder should be sent to reserve if too small.
- **Confidence**: LOW

- **Severity**: LOW
- **Location**: `pow10` function
- **Issue**: `pow10` uses a loop up to 38 iterations. This is fine, but if `n` is large (asserted <= 38), it's safe. However, the function is called in `price_8dec` with `abs_e - 8` where `abs_e` comes from Pyth expo. If Pyth expo is -38, `abs_e - 8 = 30`, safe. But if Pyth ever returns a more negative expo (e.g., -50), the `abs_e >= 8` branch triggers and `abs_e - 8` could be 42, hitting the assert. This is a safety rail, but the error is `E_DECIMAL_OVERFLOW`, which is misleading.
- **Impact**: Price fetch aborts for extreme expo values. Acceptable.
- **Recommendation**: Clarify error message.
- **Confidence**: HIGH

- **Severity**: INFO
- **Location**: Test suite
- **Issue**: No unit tests for oracle-dependent paths (`open_trove`, `redeem`, `liquidate`, `redeem_from_reserve`). These are only tested on testnet/mainnet. For an immutable contract, this is risky.
- **Impact**: Bugs in price scaling, staleness checks, or liquidation math under real Pyth feeds may slip to production.
- **Recommendation**: Mock Pyth interface in tests (even if it requires a test-only Pyth mock module) to cover these paths.
- **Confidence**: HIGH

NEEDS-FIX

---
tokens: in=13117 out=2251 dt=41.2s
