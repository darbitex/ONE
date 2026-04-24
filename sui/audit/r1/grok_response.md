# Grok (xAI) — ONE Sui R1 Response

**Received:** 2026-04-25
**Submitted:** `AUDIT_R1_SUBMISSION.md` (full)
**Verdict:** GREEN
**Findings:** none beyond accepted warnings

---

## Raw response

**Q1 — Mint-path exhaustion:** **[OK]**
The only calls to `coin::mint` for `Coin<ONE>` occur inside `open_trove` (once for the user's net amount `debt - fee` and once for the fee itself). No other function in the module calls `coin::mint<ONE>`, `coin::from_balance` on a `Balance<ONE>` that could increase supply, or any other supply-increasing operation. All other `ONE` movement is via `split`/`join`/`burn` on existing coins or balances that trace back to prior mints. The `TreasuryCap<ONE>` lives exclusively inside the shared `Registry` and is never leaked or re-parented, so the mint path is fully exhausted.

**Q2 — Burn correctness:** **[OK]**
Every burn path (`close_trove`, `redeem`/`redeem_from_reserve` (net amount), `liquidate` (debt from SP), and the 25%/100% burns inside `route_fee`) consumes exactly the expected `ONE` amount using the `TreasuryCap`. Minted supply (full `debt` in `open_trove`) is accounted for by the combination of user-held coins, `sp_pool`, `fee_pool`, and intentional burns (documented 0.25%/1% structural gaps). The invariants `total minted ≡ total burned + circulating ONE + fee_pool + sp_pool` hold exactly across all entry functions; no unaccounted supply creation or destruction exists.

**Q3 — Balance pool invariant:** **[OK]**
- `treasury_coll.value == Σ troves collateral` is preserved by `join` in `open_trove`/`add_collateral` and exact `split` in `close_trove`/`redeem`/`liquidate` (including the `target_remainder` split).
- `sp_pool.value == total_sp` is maintained by `join`/`split` paired with `total_sp +=/-=` in `sp_deposit`/`sp_withdraw`/`liquidate`.
- `fee_pool` only grows via `route_fee` (when `total_sp > 0`) and drains exclusively via `sp_settle` transfers (or is burned when SP empty).
- `reserve_coll` and `sp_coll_pool` only grow in `liquidate` (reserve/SP shares) and drain only in `redeem_from_reserve`/`sp_settle`.
No entry function violates any of these; all mutations are local to the relevant balance field.

**Q4 — Liquidation arithmetic identity:** **[OK]**
`total_seize_coll = min(floor(total_seize_usd·SUI_SCALE/price), coll)`
`liq_coll = min(floor(liq_share_usd·SUI_SCALE/price), total_seize_coll)`
`reserve_coll_amt = min(floor(reserve_share_usd·SUI_SCALE/price), total_seize_coll - liq_coll)`
`sp_coll = total_seize_coll - liq_coll - reserve_coll_amt`
`target_remainder = coll - total_seize_coll`
By construction the four terms sum exactly to `coll` in u64 arithmetic for every input (including all min-cap edge cases and zero shares). No rounding drift or missing unit is possible.

**Q5 — Redemption zombie guard:** **[OK]**
The exact sequence in `redeem` performs the two mutations first, then the two post-condition asserts:
`assert!(t.debt == 0 || t.debt >= MIN_DEBT, E_DEBT_MIN)`
`assert!(t.debt == 0 || t.collateral > 0, E_COLLATERAL)`.
`coll_out` is computed with integer division (floor) and guarded by `t.collateral >= coll_out` before mutation; `net` is guarded by `t.debt >= net`. Any input that would produce `(debt > 0 && debt < MIN_DEBT)` or `(debt > 0 && collateral == 0)` (including `coll_out == 0` at astronomical prices or `net` that leaves dust after the 1% fee) causes an abort before the transaction commits. No path can persist a zombie trove.

**Q6 — Feed-id check:** **[OK]**
`price_identifier::get_bytes(&id) == SUI_USD_PYTH_FEED` is a direct vector<u8> equality on two fixed-length 32-byte vectors (the constant feed ID). Move's vector equality is element-wise and has no special semantics for zero-length vectors here (both sides are 32 bytes). The comparison is deterministic and correct; it rejects any attacker-supplied `PriceInfoObject` with a mismatched feed ID before any price data is used.

**Q7 — Staleness ordering:** **[OK]**
`pyth::get_price_no_older_than` provides the first line of defense (its own staleness check). The subsequent manual asserts (`ts + STALENESS_SECS >= now` and `ts <= now + 10`) act as a belt-and-suspenders layer. If Pyth's semantics ever change and it stops aborting on stale prices, our asserts will still catch it and abort with `E_STALE`. The layering is sound and adds defense-in-depth with no scenario where a stale price can pass through both checks.

**Q8 — sp_settle zombie path:** **[OK]**
The early-return branch `if (snap_p == 0 || initial == 0)` simply refreshes the position's snapshots to current `product_factor`/`reward_index_*` values and returns without paying any rewards or mutating balances. Subsequent `sp_deposit` (which calls `sp_settle` first) therefore sees a freshly refreshed position and adds the new deposit on top with correct current snapshots. The regression test `test_zombie_redeposit_no_phantom_reward` exactly exercises this path and confirms no phantom rewards are paid. Coverage is complete and correct.

**Q9 — Reset-on-empty safety:** **[OK]**
The reset `if (reg.total_sp == 0) { reg.product_factor = PRECISION; }` occurs only when the pool is truly empty (all prior positions have withdrawn and been removed from the table). No active depositor exists at that moment, so the reset cannot steal or inflate any pending rewards. An attacker cannot "deposit just enough to trigger liquidation at favorable P then withdraw → reset" because after a cliff-freeze the pool must first be fully drained before the reset can fire, and liquidations are blocked below `MIN_P_THRESHOLD` anyway. The mechanism is safe under all sequences.

**Q10 — OriginCap soulbound:** **[OK]**
`OriginCap` is declared `has key` (no `store`). `sui::transfer::public_transfer` requires `T: key + store` and therefore does not compile for `OriginCap`. The module never exposes any transfer wrapper (public or otherwise) for `OriginCap`; the only `transfer::transfer` call is inside `init` to the original deployer. Pre-seal, only the deployer holds the object and can call `destroy_cap`; it cannot be transferred away via any public API.

**Q11 — destroy_cap atomicity:** **[OK]**
The sequence (assert !sealed, delete OriginCap ID, `package::make_immutable`, set `sealed = true`, emit) executes inside a single transaction. Sui/Move transaction atomicity guarantees that if any step (including the hypothetical abort of `make_immutable`) fails, the entire transaction reverts: the `OriginCap` is restored, `sealed` remains false, and no partial state is observable. The reasoning is correct.

**Q12 — Coin registry 2-step gotcha:** **[OK]**
After Tx 1 (`init`), the `Currency<ONE>` is transferred as `Receiving` to the CoinRegistry address and metadata is finalized (immutable). `finalize_registration` (called in Tx 2 PTB together with `destroy_cap`) simply promotes the `Currency<ONE>` to a shared object keyed by the ONE type. An early call to `finalize_registration` by anyone has no malicious effect—the type is fixed by the OTW, no TreasuryCap is exposed, and no alternative mint path is created. Metadata is not yet fully queryable by wallets/explorers until finalization, but this window is harmless and matches the documented deploy flow.

**Q13 — u128 overflow margins:** **[OK]**
All intermediates in `liquidate` (bonus_usd, total_seize_usd, liq_share_usd, etc.) are u128. Worst-case realistic inputs (debt = u64::MAX, price at the absolute minimum allowed by `price_8dec` with `abs_e <= 18` and `raw >= 1`) produce values well below 2¹²⁸ (maximum ~2.02e38 vs u128 max ~3.4e38). No intermediate can overflow u128.

**Q14 — conf check semantics:** **[OK]**
The check `(conf as u128) * 10000 <= (MAX_CONF_BPS as u128) * raw` rejects the price if confidence exceeds 2% of the raw price (direction is "reject if too uncertain"). `raw > 0` is asserted earlier (`E_PRICE_ZERO`), so the `raw == 0` edge is unreachable. The ordering and semantics are correct.

**Q15 — Coin<ONE> inflation via coin_registry:** **[OK]**
`coin_registry::new_currency_with_otw` + `finalize_*` only registers metadata and makes the `Currency<ONE>` discoverable; it does not expose any mint function. Minting `Coin<ONE>` still requires the `TreasuryCap<ONE>` (held inside our `Registry`). No function in `sui::coin_registry` can create `Coin<ONE>` without our `TreasuryCap`.

**Q16 — Move 2024.beta semantics:** **[OK]**
The code uses `let mut`, block-scoped mutable borrows (e.g. the `{ let pos = table::borrow_mut… }` blocks in `sp_settle`, `open_trove`, `redeem`, etc.), and field-level borrow splitting on `&mut Registry`. All borrows are properly scoped and non-overlapping; no mutable/immutable borrow conflicts exist. Table borrows are standard and compatible with 2024.beta rules. No subtle semantic differences from alpha/stable bite the contract.

**Additional findings:** None (no CRITICAL/HIGH/MEDIUM/LOW issues beyond the already-documented known limitations and the intentional 1% fee mechanics). All Sui-specific concerns (object model, sealing, coin-registry flow, Pyth integration, borrow discipline, SP math saturation, redemption guards, etc.) pass.

**Final verdict: GREEN** — ready for publish. The Sui port is clean, inherits all prior fixes, and introduces no new attack surface.

---

## Our review of the Grok response

**Cross-check vs Gemini 3.1 Pro:** 100% verdict agreement across all Q1-Q16. Both auditors independently arrive at GREEN, zero additional findings.

**Accuracy comparison:**
- **Q13 u128 margins:** Grok quotes "~2.02e38 vs ~3.4e38" — tighter/more accurate than Gemini's "~2e28". Consistent with our own numerical verification (`sp_coll × product_factor` worst = 1.845e37; `u64_max × u64_max` pessimistic = 3.403e38). Grok's figure implies knowledge of the near-tight cases.
- **Q5 redemption zombie:** Grok explicitly calls out BOTH edge cases (`coll_out == 0` at astronomical prices AND `net` that leaves dust after 1% fee). More thorough than Gemini's version.
- **Q8 regression test:** Grok references `test_zombie_redeposit_no_phantom_reward` by name — confirms actual test-file engagement.
- **Q9 attack scenario:** Grok directly addresses the posed attack ("deposit just enough to trigger liquidation at favorable P then withdraw → reset") — explicit refutation via cliff-freeze guard + MIN_P_THRESHOLD.

**No disagreements.** Two independent auditors converge on GREEN with mutually reinforcing reasoning.

## Accept / reject

**ACCEPT.** No code changes. Verdict reinforces Gemini's GREEN. Two of four R1 auditors complete, both clean.
