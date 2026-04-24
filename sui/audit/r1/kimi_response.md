# Kimi — ONE Sui R1 Response

**Received:** 2026-04-25
**Submitted:** `AUDIT_R1_SUBMISSION.md` (full)
**Verdict:** GREEN
**Findings:** 1 INFO (saturation-logic dead-code observation) — technical, pending user decision.

---

## Raw response

# ONE Sui Stablecoin — Round 1 External Audit Report

## Q1 — Mint-path exhaustion
**[OK]** `open_trove` is the sole production mint path. It calls `coin::mint(&mut reg.treasury, debt - fee, ctx)` and `coin::mint(&mut reg.treasury, fee, ctx)`. No other `public` or `entry` function invokes `coin::mint`, `coin::from_balance` on a `Balance<ONE>`, or any other supply-increasing operation. The `TreasuryCap<ONE>` is stored exclusively in the shared `Registry` and never extracted or exposed. Test-only helpers (`test_mint_origin_cap`, etc.) do not touch the treasury.

## Q2 — Burn correctness
**[OK]** The supply invariant holds. Every `Coin<ONE>` minted in `open_trove` is accounted for by: (a) burning in `close_trove` (debt amount), (b) burning in `redeem` (net amount), (c) burning in `liquidate` (debt from `sp_pool`), (d) burning in `redeem_from_reserve` (net amount), (e) burning in `route_fee` (25% of fee, or 100% when `total_sp == 0`), or (f) remaining in circulation or in `fee_pool` / `sp_pool`. `redeem_from_reserve`'s intentional non-reduction of `total_debt` is an accounting divergence, not a supply bug — the coins are still burned.

## Q3 — Balance pool invariant
**[OK]** All four invariants are maintained:
- `treasury_coll`: incremented only in `open_trove`/`add_collateral` (joining user collateral); decremented only in `close_trove`, `redeem`, and `liquidate` (splitting exactly the trove's collateral or seized amount). The `liquidate` path splits `total_seize_coll` + `target_remainder == coll` from `treasury_coll`, matching the removed trove.
- `sp_pool`: synchronized with `total_sp` in `sp_deposit` (+), `sp_withdraw` (-), and `liquidate` (-debt).
- `fee_pool`: grows only via `route_fee` (when `total_sp > 0`), drains only via `sp_settle`.
- `reserve_coll`: grows only in `liquidate`, drains only in `redeem_from_reserve`.
- `sp_coll_pool`: grows only in `liquidate`, drains only in `sp_settle`.

## Q4 — Liquidation arithmetic identity
**[OK]** The identity holds exactly. By construction:
- `total_seize_coll = min(total_seize_u128, coll_u128)`
- `liq_coll = min(liq_u128, total_seize_coll)`
- `reserve_coll_amt = min(reserve_u128, total_seize_coll - liq_coll)`
- `sp_coll = total_seize_coll - liq_coll - reserve_coll_amt`
- `target_remainder = coll - total_seize_coll`

Summing: `liq_coll + reserve_coll_amt + sp_coll + target_remainder = total_seize_coll + (coll - total_seize_coll) = coll`. Integer truncation occurs only inside each individual term, but the algebraic identity is preserved by the sequential `min` clamping.

## Q5 — Redemption zombie guard
**[OK]** No input combination can produce `(coll=0, debt>0)`. The pre-conditions `assert!(t.collateral >= coll_out)` and `assert!(t.debt >= net)` ensure the subtractions are safe. The post-conditions `assert!(t.debt == 0 || t.debt >= MIN_DEBT)` and `assert!(t.debt == 0 || t.collateral > 0)` enforce that any remaining debt implies positive collateral. Since `one_amt >= MIN_DEBT`, `fee >= MIN_DEBT/100 > 0`, so `net > 0` always. If `coll_out == 0` (astronomical price), `t.collateral` is unchanged and remains > 0 for any remaining debt.

## Q6 — Feed-id check
**[OK]** The comparison `price_identifier::get_bytes(&id) == SUI_USD_PYTH_FEED` is a standard Move vector equality. Pyth price identifiers are fixed-width 32-byte arrays; the constant `SUI_USD_PYTH_FEED` is exactly 32 bytes. There is no semantic issue with zero-length vectors or variable-length matching.

## Q7 — Staleness ordering
**[OK]** The layering is sound. `pyth::get_price_no_older_than` performs Pyth's internal staleness check against the `PriceInfoObject`'s cached timestamp. The subsequent `assert!(ts + STALENESS_SECS >= now)` and `assert!(ts <= now + 10)` provide defense in depth. If Pyth's internal check were ever bypassed or changed to a no-op, the explicit assertions still bound the acceptable timestamp window. The `now + 10` skew tolerance is reasonable for blockchain clock variance.

## Q8 — sp_settle zombie path
**[OK]** The early-return branch (`snap_p == 0 || initial == 0`) correctly refreshes snapshots to the current global state before returning. A subsequent `sp_deposit` (which calls `sp_settle` first) will either find the position removed (if `sp_withdraw` emptied it) or will find `initial == 0` with fresh snaps, then increment `initial_balance` by the new deposit amount. No phantom reward is inherited because the delta indices are reset to zero relative to the current global state. The R2-C01 regression test coverage is correct.

## Q9 — Reset-on-empty safety
**[OK]** The reset cannot be exploited. The reset occurs only when `reg.total_sp == 0`, meaning no active depositor exists to be harmed. An attacker depositing, triggering liquidation, withdrawing, and redepositing gains no advantage: they absorb the same proportional loss any depositor would, and resetting `product_factor` to `PRECISION` merely restores the initial accounting scale. There is no value extraction from the reset itself; the attacker's economic position is identical to simply staying deposited.

## Q10 — OriginCap soulbound
**[OK]** `OriginCap` has `key` but no `store`. `sui::transfer::public_transfer` requires the transferred type to have `store`, so it will not compile for `OriginCap`. The module exposes no custom transfer wrapper. The deployer receives it in `init` via `transfer::transfer`, and it can only be consumed by `destroy_cap`. It is effectively soulbound.

## Q11 — destroy_cap atomicity
**[OK]** The reasoning is correct. Move transactions are fully atomic. If `package::make_immutable` were to abort (hypothetically), all writes—including the `OriginCap` unpack and field mutations—are reverted. The `OriginCap` would be restored to the deployer, and `reg.sealed` would remain `false`. No partial state is observable.

## Q12 — Coin registry 2-step gotcha
**[OK]** No front-running or malicious substitution is possible. `coin_registry::finalize_and_delete_metadata_cap` TTOs the exact `Currency<ONE>` object (authenticated by the `ONE` OTW type) to the CoinRegistry address. The follow-up `finalize_registration` call requires the specific `Receiving<Currency<ONE>>` derived from that TTO. An attacker cannot forge a `Currency<ONE>` because `Currency` is a one-time-witness-gated type, and they cannot intercept the `Receiving` object because it is bound to the CoinRegistry address.

## Q13 — u128 overflow margins
**[OK]** No intermediate u128 can overflow. The maximum realistic intermediate is bounded by:
- Max debt ≈ u64::MAX (~1.84×10¹⁹)
- `LIQ_BONUS_BPS` = 1000
- `SUI_SCALE` = 10⁹

Max chain: `debt × LIQ_BONUS_BPS / 10000 × SUI_SCALE / price` ≤ `1.84×10¹⁹ × 10³ × 10⁹` ≈ `1.84×10³¹`, far below u128::MAX (~3.4×10³⁸). Even at price = 1, the result is well within bounds.

## Q14 — conf check semantics
**[OK]** The inequality direction is correct. `(conf * 10000 <= MAX_CONF_BPS * raw)` is equivalent to `conf/raw <= MAX_CONF_BPS/10000 = 0.02`. The assertion aborts when confidence exceeds 2% of the price, which is the intended "reject if uncertain" behavior. The `raw == 0` case is guarded by the preceding `assert!(raw > 0, E_PRICE_ZERO)`.

## Q15 — Coin<ONE> inflation via coin_registry
**[OK]** No. The `Currency<ONE>` shared object created by `coin_registry` contains only metadata (name, symbol, decimals, etc.). Minting `Coin<ONE>` requires `&mut TreasuryCap<ONE>`, which is stored exclusively in `Registry.treasury` and only accessed in `open_trove` (mint) and burn sites. The `coin_registry` module has no minting capability.

## Q16 — Move 2024.beta semantics
**[OK]** No borrow-discipline issues were found. The code correctly uses block-scoped borrows to release `&mut Registry` field borrows before borrowing other fields. For example, in `sp_settle`, the immutable borrow of `r.sp_positions` is released before the subsequent mutable borrow of `r.fee_pool`. Field-level borrow splitting is used correctly throughout. `let mut` bindings are properly scoped.

---

## Additional Findings

### INFO-01: `sp_settle` saturation cap is unnecessary and theoretically fragile
**Location:** `sp_settle`, lines computing `pending_one`, `pending_coll`, `new_balance`
**Description:** The u64 saturation logic (`if (one_trunc) u64_max`) is dead code under all economically realizable protocol states. Total fees are bounded by total debt, which is bounded by total SUI collateral; `raw_one` and `raw_coll` cannot reach `u64::MAX` in practice. More importantly, if the saturation were ever triggered, `balance::split(&mut r.fee_pool, u64::MAX)` would abort when the pool holds less than `u64::MAX`, defeating the stated purpose of preventing permanent position lock.
**Recommendation:** Remove the saturation logic and the `u64_max` constant, or cap payouts to `min(raw, pool_balance)` instead. The `raw_bal` saturation is also unnecessary because `product_factor <= snapshot_product` always implies `raw_bal <= initial <= u64::MAX`.

---

## Final Verdict

**GREEN**

The ONE Sui protocol is well-constructed and exhibits no critical, high, or medium severity issues. The mint path is properly constrained, liquidation arithmetic is exact, redemption zombie guards are effective, the sealing mechanism is atomic and irreversible, and the Pyth integration is correctly parameterized. The single INFO finding (INFO-01) identifies unnecessary defensive code that is harmless in practice and does not affect mainnet safety. The codebase is cleared for publish.

---

## Documentation notes (no action taken)

**Cross-check vs Gemini + Grok + Qwen + DeepSeek:** 5/5 independent auditors converge on GREEN. Q1–Q16 verdicts 100% identical across all five.

**Kimi-unique finding — INFO-01 (sp_settle saturation dead-code):**

Kimi makes two technical claims:
1. The u64 saturation logic in `sp_settle` is dead code because reward totals are economically bounded by SUI collateral (itself bounded by u64::MAX, but realistic totals are much smaller).
2. If saturation WERE triggered, `balance::split(&mut r.fee_pool, u64::MAX)` would abort (because fee_pool holds less than u64::MAX), defeating the claimed "prevents permanent position lock" purpose.

Observation 2 is a substantive counter-argument to the saturation logic's stated intent. Worth flagging for user review, but not applied per user instruction ("jangan buat apa apa dulu, hanya kumpulkan dan dokumentasikan hasil audit").

**Status: DOCUMENTED only. Not applied, not rejected.**
