# Gemini 3.1 Pro — ONE Sui R1 Response

**Received:** 2026-04-25
**Submitted:** `AUDIT_R1_SUBMISSION.md` (full)
**Verdict:** GREEN
**Findings:** none beyond accepted warnings

---

## Raw response

### ONE Sui Stablecoin — Round 1 External Audit Report

As with any strict mainnet release audit, the review was conducted with the understanding that post-seal immutability makes all surviving logic permanent. The codebase demonstrates an exceptionally high degree of defensive programming, correctly porting Liquity V1 mathematics while successfully adapting to Sui's object model and Move 2024.beta semantics.

Below are the detailed evaluations of the targeted focus areas.

### Focus Areas (High & Medium Priority)

**Q1 — Mint-path exhaustion: [OK]**
A rigorous check of the `sui::coin` usages confirms that `coin::mint` is exclusively called within `open_trove`. The required `TreasuryCap<ONE>` is strictly encapsulated inside the `Registry` shared object, and no other internal or public function borrows `reg.treasury` mutably for minting purposes. Supply inflation vectors outside of collateralized trove opening are completely sealed.

**Q2 — Burn correctness: [OK]**
The burn mechanics maintain the core supply invariant. Every protocol pathway that decreases user debt or processes a fee correctly routes to `coin::burn`. The `route_fee` logic accurately handles the 25/75 split, and `liquidate`, `redeem`, and `close_trove` account for their respective balance destructions without leaving orphaned supply.

**Q3 — Balance pool invariant: [OK]**
All state mutations affecting `treasury_coll`, `sp_pool`, `fee_pool`, `reserve_coll`, and `sp_coll_pool` are paired with precise `balance::join` and `balance::split` operations. The complex `liquidate` path correctly decrements the exact aggregate sum of `target_remainder` and `total_seize_coll` from the treasury, perfectly preserving the `treasury_coll.value == Σ troves[i].collateral` invariant under all CR scenarios.

**Q4 — Liquidation arithmetic identity: [OK]**
The identity `liq_coll + reserve_coll_amt + sp_coll + target_remainder == coll` mathematically holds across all edge cases. By deriving `sp_coll` and `target_remainder` through direct subtraction of the preceding bounded allocations (`total_seize_coll - liq_coll - reserve_coll_amt` and `coll - total_seize_coll`), the logic guarantees no rounding drift or phantom collateral generation.

**Q5 — Redemption zombie guard: [OK]**
The ported M-01 supra patch is sound. Because `fee` is strictly a percentage of `one_amt`, `net` will always be greater than 0 (given `MIN_DEBT`). Consequently, a redemption will always actively decrease debt. The subsequent assertions successfully prevent an un-closable zombie state of `(coll=0, debt>0)` from forming, even at extreme oracle prices.

**Q6 — Feed-id check: [OK]**
Move's vector equality operator (`==`) is a byte-by-byte comparison. While not constant-time at the VM level, timing attacks are irrelevant for Sui smart contracts since transaction outcomes are deterministic and executed fully on-chain. The comparison securely guarantees that an attacker cannot inject a validly signed Pyth `PriceInfoObject` from a different asset feed.

**Q7 — Staleness ordering: [OK]**
The layered defense is architecturally robust. If Pyth's internal `get_price_no_older_than` fails to abort on a stale price (due to a hypothetical future Pyth contract upgrade), your hardcoded timestamp check (`assert!(ts + STALENESS_SECS >= now, E_STALE)`) acts as a guaranteed safety net. The `+10` seconds forward-check cleanly accounts for minor clock drift.

**Q8 — sp_settle zombie path: [OK]**
The R2-C01 regression fix natively catches the edge case. If `initial == 0`, `sp_settle` refreshes the snapshot metrics to the current global state and returns. A subsequent `sp_deposit` by the same user triggers `sp_settle` again, which processes cleanly without accruing phantom rewards, and then safely increments `initial_balance`.

**Q9 — Reset-on-empty safety: [OK]**
The `product_factor` reset logic within `sp_deposit` is mathematically isolated and secure. Because the reset only triggers precisely when `reg.total_sp == 0`, there are no active depositors whose historical snapshot ratios could be corrupted. An attacker cannot exploit this because withdrawing their balance to force a reset inherently removes their ability to claim rewards from the subsequent state.

**Q10 — OriginCap soulbound: [OK]**
By omitting the `store` ability, `OriginCap` is strictly constrained by the Move type system. It cannot be wrapped, placed in a shared object, or transferred via `sui::transfer::public_transfer`. It remains permanently bound to the deployer's address until consumed by `destroy_cap`.

**Q11 — destroy_cap atomicity: [OK]**
Move's transactional atomicity ensures that if `package::make_immutable` hypothetically aborts, the entire transaction context reverts. The deletion of the `OriginCap` and the toggling of `reg.sealed` would be rolled back entirely, returning the state to the exact condition prior to the transaction execution.

**Q12 — Coin registry 2-step gotcha: [OK]**
The separation of deployment into two transactions introduces no actionable vulnerability. The `coin_registry::finalize_registration` function is inherently permissionless; if an adversary front-runs the second transaction, they merely subsidize the protocol's setup costs by paying the gas to finalize the immutable coin metadata.

**Q13 — u128 overflow margins: [OK]**
Maximum theoretical inputs (debt near `u64::MAX` and nominal prices) yield intermediate `u128` values around `2e28`. With the `u128` ceiling resting at approximately `3.4e38`, there are 10 orders of magnitude providing a massive buffer. Overflow is virtually impossible under any realistic or extreme network conditions.

**Q14 — conf check semantics: [OK]**
The logic `assert!((conf as u128) * 10000 <= (MAX_CONF_BPS as u128) * raw, E_PRICE_UNCERTAIN)` correctly enforces a pass-if-true constraint. As confidence widens (becomes more uncertain), the left side of the inequality grows, correctly triggering the abort. The prior `raw > 0` check guarantees the right side is non-zero, preventing division-by-zero equivalents.

**Q15 — Coin<ONE> inflation via coin_registry: [OK]**
The `sui::coin_registry` framework does not natively possess minting capabilities. Under Sui framework rules, `coin::mint` inherently requires mutable access to the specific `TreasuryCap<T>`. Because the cap is strictly locked inside the `Registry`, the Coin Registry cannot bypass standard inflation controls.

**Q16 — Move 2024.beta semantics: [OK]**
The implementation fully aligns with Move 2024.beta requirements. Block-scoped mutable borrows (`let mut`) are handled cleanly, and field-level borrow splitting within the shared `&mut Registry` context correctly avoids overlapping mutable references. The Sui verifier would strictly reject the bytecode if lifetime violations existed.

---

### Additional Findings

No additional vulnerabilities, precision loss vectors, or logic flaws were identified outside of the established and acknowledged warning constants. The codebase is highly optimized for its specific threat model.

### Final Verdict

**GREEN** — The ONE Sui package (v0.1.0) architecture is sound, the Liquity V1 port is mathematically accurate, and the Sui-specific integrations are secure. The code clears external auditing standards for mainnet publish and subsequent immutable sealing.

---

## Our review of the Gemini response

**Build + tests reconfirmed post-audit:** `sui move test` runs `19/19 PASS`. Source unchanged after audit.

**Spot-check Q13 (u128 overflow margins):** Gemini claims "~2e28 worst case, ~10 orders of magnitude margin."

Actual worst-case computed numerically via `python3` exhaustive chain analysis:

| Chain | Worst value | u128 margin |
|---|---|---|
| `sp_coll × product_factor` (liquidate new_p + reward_index_coll update) | 1.845e37 | 18× (~4 bits spare) |
| `sp_amt × product_factor` (route_fee reward_index_one update) | 1.845e37 | 18× |
| `new_coll × price` (u64 max both, MCR check) | 3.403e38 | ≈1.0× (tight but fits; ~2^65 absolute spare) |
| `delta_idx × initial` (sp_settle u256 numerator) | 6.3e57 | 1.8e19× (u256 path) |

Gemini's magnitude claim is off by ~9 orders. Conclusion (SAFE) holds — Move aborts cleanly on overflow (no silent truncation), and the tightest u128 case still has 18× margin which is adequate for realistic operational lifetime. The "1×-margin `u64_max × u64_max`" case in `open_trove` MCR check only triggers at price ≈ $1.8e11 per SUI which is economically absurd AND still fits u128 (by 2^65 = ~3.7e19).

**Spot-check Q5 (redemption zombie with coll_out=0):** Re-traced all 3 sub-scenarios for hypothetical astronomical price where `coll_out` rounds to 0:
- Scenario A (`t.debt == net`): debt→0, collateral unchanged. Post-condition `t.debt==0` short-circuits. OK.
- Scenario B (`t.debt == net + MIN_DEBT`): debt→MIN_DEBT, collateral unchanged>0. Both post-conditions pass. OK.
- Scenario C (`t.debt == net + 1`): debt→1, post-condition `t.debt>=MIN_DEBT` fails → **E_DEBT_MIN abort → tx reverts → no state change → no zombie**.

Confirmed: no zombie possible even at coll_out=0 extreme. Gemini's reasoning sound.

**Q16 (Move 2024.beta semantics):** Gemini's claim that "Sui verifier would strictly reject the bytecode if lifetime violations existed" is accurate — the Sui Move bytecode verifier enforces borrow discipline at publish time, not just at compile. Our implementation passes both `sui move build` and `sui move test` (19/19), confirming both the compile-time checker and test-time borrow machinery accept the code.

All other answers technically substantive. No material errors in Gemini's analysis beyond the overstated u128 margin (which doesn't affect the correctness verdict).

## Accept / reject

**ACCEPT** this response as a valid R1 audit input. No diffs requested, no changes needed. Gemini's conclusion GREEN stands; our numerical re-verification confirms no actual overflow vectors exist within realistic operational parameters.
