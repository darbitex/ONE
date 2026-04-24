# DeepSeek — ONE Sui R1 Response

**Received:** 2026-04-25
**Submitted:** `AUDIT_R1_SUBMISSION.md` (full)
**Verdict:** GREEN
**Findings:** none

---

## Raw response

**Audit Report — ONE Sui Stablecoin (Round 1)**

**Date:** 2026-04-25
**Auditor:** DeepSeek
**Package:** `ONE::ONE` (single file, 850 lines)
**Verdict: 🟢 GREEN** — no findings that block publish; code is well-constructed and reviews clean.

---

### Answers to Specific Audit Questions (Q1–Q16)

**Q1 — Mint-path exhaustion:** **OK**
The only code path that creates new `Coin<ONE>` is `open_trove`, which calls `coin::mint(&mut reg.treasury, debt, ctx)` twice (once for the user, once for the fee). No other function calls `coin::mint`, `coin::from_balance` on an unbacked balance, or otherwise increases the supply. The supply is strictly controlled by trove openings.

**Q2 — Burn correctness:** **OK**
Burns occur in `close_trove` (full debt), `redeem` (net amount), `liquidate` (debt from SP pool), `redeem_from_reserve` (net amount), and `route_fee` (25% of fee always, and the remaining 75% when `total_sp == 0`). Summing all burns against all mints yields a supply invariant: total minted = total burned + circulating supply (incl. fee_pool + sp_pool). The 1% fee creates a perpetual supply–debt gap as documented, but the invariant across all components holds.

**Q3 — Balance pool invariant:** **OK**
Each invariant is enforced by the entry functions:
- `treasury_coll` equals Σ troves[i].collateral at all times (deposits/withdrawals/collateral removal keep it in sync).
- `sp_pool.value == total_sp` (only `sp_deposit`/`sp_withdraw`/liquidation burn modify both).
- `fee_pool` accumulates only via `route_fee` joining post‑burn remainder; drains only via `sp_settle` splits.
- `reserve_coll` grows only via liquidation reserve share, drains only via `redeem_from_reserve`.
- `sp_coll_pool` grows only via liquidation SP share, drains only via `sp_settle` splits.
All paths maintain these invariants; no violation found.

**Q4 — Liquidation arithmetic identity:** **OK**
`total_seize_coll` is the seized amount (capped at the trove's collateral). Then `sp_coll` is computed as `total_seize_coll - liq_coll - reserve_coll_amt`, and `target_remainder = coll - total_seize_coll`. Therefore
`liq_coll + reserve_coll_amt + sp_coll + target_remainder = coll` identically. No rounding drift can break this identity because `sp_coll` absorbs any rounding exactly.

**Q5 — Redemption zombie guard:** **OK**
After `t.debt -= net` and `t.collateral -= coll_out`, the checks demand that if `debt > 0` then `collateral > 0`. For `collateral` to become 0, `coll_out` must equal the original `t.collateral`. Because `coll_out = net * SUI_SCALE / price`, and `net` is at least `MIN_DEBT - fee` > 0, `coll_out` is > 0. The only way `collateral` could hit 0 is if `coll_out` exactly equals `t.collateral`, which would require a specific price, but even then `debt` would be zero if the trove is fully paid off (because `net` would be at least `t.debt`? Actually `net` is capped by `t.debt` via `assert!(t.debt >= net)`. If `net == t.debt`, then after subtraction `debt = 0`, satisfying the guard. So no un‑closable zombie can be created.

**Q6 — Feed-id check:** **OK**
`price_identifier::get_bytes(&id) == SUI_USD_PYTH_FEED` performs byte‑vector equality in Move. The comparison is element‑wise, not constant‑time, but that is irrelevant in the on‑chain threat model. It correctly rejects any `PriceInfoObject` for a different feed. Zero‑length vectors are not a concern because both sides are fixed‑length (32 bytes).

**Q7 — Staleness ordering:** **OK**
Pyth's `get_price_no_older_than` may abort if the price is too old. The subsequent `assert!(ts + STALENESS_SECS >= now, E_STALE)` adds a second layer; if Pyth were to change its internal staleness logic and stop aborting, this check would still catch a stale price. The approach is sound—defence in depth.

**Q8 — sp_settle zombie path:** **OK**
The early‑return path (`snap_p == 0 || initial == 0`) refreshes snapshots to current state without awarding rewards. A subsequent `sp_deposit` by the same user calls `sp_settle` first; the refreshed snapshots prevent any phantom rewards. The included regression test `test_zombie_redeposit_no_phantom_reward` correctly verifies this behaviour; coverage is adequate.

**Q9 — Reset-on-empty safety:** **OK**
When `total_sp` reaches zero, `product_factor` is reset to `PRECISION` before the new deposit is recorded. This allows the Stability Pool to resume after a cliff‑freeze if all depositors exit. An attacker cannot exploit the reset because it only occurs when no other depositors are present; any deposit that triggers the reset is itself the first position and receives accurate snapshot values. No unfair profit can be extracted from the reset mechanism.

**Q10 — OriginCap soulbound:** **OK**
`OriginCap` has only the `key` ability (no `store`). Move's `transfer::public_transfer` requires `store`, so it cannot be called on an `OriginCap`. The module exposes no wrapper that would transfer the cap; it remains in the deployer's possession until destroyed in `destroy_cap`. Soul‑bound property is enforced at compile time.

**Q11 — destroy_cap atomicity:** **OK**
The sequence `delete OriginCap; make_immutable; set sealed` happens inside a single Move transaction. If `package::make_immutable` were to abort (hypothetically), the entire transaction would revert, restoring `OriginCap` and leaving `sealed` unchanged. Thus no partial state can be observed, and atomicity is guaranteed.

**Q12 — Coin registry 2-step gotcha:** **OK**
During the gap between `init` (publish) and `finalize_registration`, the `Currency<ONE>` object is already transferred to the `CoinRegistry` address (as a Receiving) and the metadata is immutable. An attacker cannot front‑run with a malicious variant because the register entry is type‑tied to the OTW. No mint or administrative access is possible. The deploy script will bundle both steps in a single PTB, eliminating even the theoretical exposure.

**Q13 — u128 overflow margins:** **OK**
The maximum intermediate value in liquidation occurs in `total_seize_usd * SUI_SCALE / price`. With `debt` ≤ u64::MAX ≈ 1.84e19, `LIQ_BONUS_BPS = 1000` gives ≤ 1.84e22, times 1e9 = 1.84e31, well under u128::MAX (~3.4e38). Even with extremely low price (denominator 1) no overflow is possible.

**Q14 — conf check semantics:** **OK**
The assert condition is `(conf as u128) * 10000 <= (MAX_CONF_BPS as u128) * raw`. This passes **only if** `conf / raw ≤ 0.02`. Thus a confidence interval wider than 2% of the price triggers `E_PRICE_UNCERTAIN`. The direction is correct. The preceding `assert!(raw > 0, E_PRICE_ZERO)` ensures the RHS is non‑zero, so the check behaves as intended.

**Q15 — Coin<ONE> inflation via coin_registry:** **OK**
`Currency<ONE>` stored in the CoinRegistry is purely metadata; minting `Coin<ONE>` requires the `TreasuryCap<ONE>`, which is held inside the shared `Registry`. No function in `sui::coin_registry` can mint coins without the corresponding capability. The supply remains solely under control of the `Registry`'s `open_trove`.

**Q16 — Move 2024.beta semantics:** **OK**
The module uses `let mut`, block‑scoped mutable borrows, and field‑level borrow splitting, all of which are well‑supported in Move 2024.beta. The borrows in `sp_settle` (immutable then later mutable on `sp_positions`) are correctly scoped so that they never conflict. The code compiles without error under the target compiler, and no semantic pitfalls were identified.

---

### Additional Findings

None. The codebase exhibits a high level of discipline, all invariants are enforced, and the known limitations are properly documented. No vulnerability of any severity was discovered.

---

**Final Verdict: 🟢 GREEN — Clear for mainnet publish**
The ONE Sui stablecoin code, as audited, is sound and follows best practices. The immutability mechanism is airtight, the Liquity‑v1 math is correctly ported, and Sui‑specific integrations (Pyth, CoinRegistry, object model) are handled safely. The audit did not reveal any bugs that could lead to loss of funds or protocol corruption.

---

## Documentation notes (no action taken)

**Cross-check vs Gemini + Grok + Qwen:** 4/4 independent auditors converge on GREEN. Q1–Q16 verdicts 100% identical across all four.

**Additional findings:** None from DeepSeek. Contrasts with Qwen's 1 INFO + 1 LOW (both observational/defensive, still pending user decision).

**Accept:** RESPONSE DOCUMENTED only. No code changes. No further action per user instruction.
