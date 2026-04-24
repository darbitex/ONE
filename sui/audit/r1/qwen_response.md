# Cerebras Qwen3-235B — ONE Sui R1 Response

**Received:** 2026-04-25
**Submitted:** `AUDIT_R1_SUBMISSION.md` (full)
**Verdict:** GREEN
**Findings:** 2 (1 INFO, 1 LOW) — both non-safety, observational/defensive only. User decision pending.

---

## Raw response

### Audit Responses: Q1–Q16

**Q1 — [OK]**
Only `open_trove` invokes `coin::mint(&mut reg.treasury, ...)`, and it does so exactly twice: once for the net user amount (`debt - fee`) and once for the fee portion. All other code paths exclusively operate on pre-existing `Balance<ONE>` objects via `balance::split/join` or `coin::burn`. No `coin::from_balance` or registry function can generate new supply without the `TreasuryCap`, which is structurally owned and guarded by `Registry`. The mint path is cryptographically exhausted.

**Q2 — [OK]**
The burn/mint accounting identity holds across all execution paths. `open_trove` mints `debt`; `close_trove` burns `debt`; `redeem`/`redeem_from_reserve` burn `net` while routing/burning the `fee`; `liquidate` burns `debt` from `sp_pool`; `route_fee` deterministically burns 25% (or 100% if SP empty). The sum of all burns exactly equals the sum of all mints minus the circulating `fee_pool`/`sp_pool` balances, preserving the canonical CDP supply invariant. No arithmetic drift or unaccounted fee leakage exists.

**Q3 — [OK]**
Each pool invariant is strictly enforced by paired state mutations. `treasury_coll` is only modified via `balance::join` (deposit/collateral add) and `balance::split` (redemption/liquidation/close). `sp_pool` mirrors `total_sp` exactly through `sp_deposit`, `sp_withdraw`, and liquidation debt burns. `fee_pool` grows only via `route_fee` joins and drains only via `sp_settle` splits or explicit burns. `reserve_coll` and `sp_coll_pool` follow identical join/split discipline tied to liquidation proceeds and SP claims. No untracked balance operations exist.

**Q4 — [OK]**
The liquidation collateral partition uses sequential `min` clamping that guarantees exact accounting: `liq_coll` is capped at `total_seize_coll`, `reserve_coll_amt` is capped at the remainder, and `sp_coll` is defined as the residual. `target_remainder` is explicitly `coll - total_seize_coll`. Summing these yields `total_seize_coll + (coll - total_seize_coll) = coll` exactly. Integer division truncation occurs before clamping, ensuring the partition never exceeds the trove's actual collateral. The identity holds for all valid inputs, including zero-value distributions.

**Q5 — [OK]**
The dual post-conditions in `redeem` perfectly prevent zombie troves. If `net < debt`, `t.debt > 0` triggers the second assertion, forcing `t.collateral > 0` and rejecting any `(coll=0, debt>0)` state. If `net == debt` (full redemption), `t.debt == 0` short-circuits both checks, correctly allowing the trove to close at `(0,0)`. The `MIN_DEBT` gate ensures `net` can never round to zero given `one_amt >= 1e8`, and astronomical prices only reduce `coll_out` without bypassing the collateral guard.

**Q6 — [OK]**
Move's native `vector<u8>` equality operator checks length first, then performs element-wise comparison. It correctly rejects mismatched feed IDs and safely handles zero-length or partial vectors without false positives. While not constant-time, timing side-channels are explicitly out of scope per your threat model, and the comparison provides unambiguous cryptographic feed validation.

**Q7 — [OK]**
The layered staleness validation is sound. Pyth's internal check acts as the first gate, while the explicit `ts <= now + 10` assertion prevents future-dated price manipulation or extreme clock skew. If Pyth's internal semantics regress and fail to abort on stale data, the redundant `ts + STALENESS_SECS >= now` check catches it. The ordering guarantees that only prices within the acceptable historical window (±10s tolerance) proceed.

**Q8 — [OK]**
The early return correctly handles zombie positions by refreshing snapshots to current global state without awarding phantom rewards. Since `initial_balance` remains `0`, the subsequent `sp_deposit` call will invoke `sp_settle`, see `initial == 0`, return early again, and then add the new deposit amount. Reward accrual correctly starts from the refreshed baseline. The existing regression test adequately covers this invariant.

**Q9 — [OK]**
The reset condition `reg.total_sp == 0` is mutually exclusive with the liquidation requirement `reg.total_sp > debt`. An attacker cannot trigger both in the same sequence because liquidation requires active SP liquidity, while the reset requires complete SP depletion. Depositors cannot manipulate the reset to their advantage because no active positions exist when `total_sp == 0`, leaving no mathematical foothold for extraction.

**Q10 — [OK]**
The absence of the `store` capability on `OriginCap` prevents compilation of `sui::transfer::public_transfer` or any standard object transfer mechanism. Move's capability system strictly enforces that non-`store` objects cannot be passed by value into transfer functions or nested inside other objects. The module exposes no custom transfer wrappers, guaranteeing the cap remains soulbound to the deployer's address until `destroy_cap` consumes it.

**Q11 — [OK]**
Sui's transaction model guarantees full atomicity. If `package::make_immutable` aborts for any reason, the entire PTB reverts to its pre-execution state, including restoring the deleted `OriginCap` via `object::delete` rollback and leaving `reg.sealed` as `false`. No observable partial state can persist on-chain, and the `UpgradeCap` remains valid for retry.

**Q12 — [OK]**
The `Currency<ONE>` object is transferred as a `Receiving` capability to the CoinRegistry's derived address immediately after `init`, making it inaccessible to external actors. Metadata is already finalized and immutable via `finalize_and_delete_metadata_cap`. The `finalize_registration` step merely promotes the locked `Receiving` object to a shared global index; front-running or injecting malicious metadata is impossible due to Move's object ownership and registry derivation rules.

**Q13 — [OK]**
Even at theoretical extremes (`debt = u64::MAX ≈ 1.84e19`, `price = 1`), the intermediate calculation `(debt * 1000 / 10000) * 1e9` yields `~1.84e27`, which is well within the `u128` maximum of `~3.4e38`. Subsequent division by `price` only reduces magnitude. The `u128` type provides over 10 orders of magnitude headroom, making overflow mathematically impossible under any valid oracle or debt input.

**Q14 — [OK]**
The inequality `(conf * 10000) <= (MAX_CONF_BPS * raw)` correctly passes when confidence is within the 2% threshold and aborts when it exceeds it. The prior `assert!(raw > 0, E_PRICE_ZERO)` ensures the RHS is strictly positive, preventing degenerate zero-comparison or division-by-zero edge cases. The direction aligns precisely with the intent to reject prices with wide Pyth confidence intervals.

**Q15 — [OK]**
Sui's `coin_registry` module is purely for metadata registration, type discovery, and explorer indexing. It holds zero minting authority and cannot interact with `TreasuryCap`. All `coin::mint` operations cryptographically require `&mut TreasuryCap<ONE>`, which is owned exclusively by the `Registry` struct and never exposed publicly. The registry APIs cannot bypass this ownership model.

**Q16 — [OK]**
The code correctly adheres to Move 2024.beta borrow semantics. Block-scoped borrows in `sp_settle` and `liquidate` use explicit `{}` blocks to drop immutable `table::borrow` references before acquiring `table::borrow_mut` or `&mut reg` fields. Field-level splitting avoids aliasing `Registry` by accessing distinct fields or using temporary references. No overlapping mutable/immutable borrows exist, and `let mut` bindings are correctly scoped to prevent use-after-move errors.

---

### Additional Findings

**[INFO] `sp_claim` emits no event on zero rewards**
- **Location:** `sources/ONE.move:sp_settle` / `sp_claim`
- **Description:** When a user calls `sp_claim` and has no pending rewards (`pending_one == 0 && pending_coll == 0`), the function returns silently without emitting an event. Off-chain indexers tracking claim activity or SP interactions may miss these zero-yield calls, complicating user behavior analysis.
- **Recommendation:** Emit `SPClaimed { user, one_amt: 0, coll_amt: 0 }` unconditionally, or add a lightweight `SPClaimAttempted` event. Not a security risk, but improves observability.

**[LOW] `now + 10` overflow edge in staleness check**
- **Location:** `sources/ONE.move:price_8dec` (~line 142)
- **Description:** `assert!(ts <= now + 10, E_STALE)` performs unsigned addition. If `now` reaches `u64::MAX - 9`, `now + 10` will panic on overflow before the comparison. While practically impossible (timestamp won't hit `u64::MAX` for centuries), it violates strict defensive programming standards for immutable contracts.
- **Recommendation:** Replace with `assert!(now <= u64::MAX - 10 && ts <= now + 10, E_STALE)` or use `now.checked_add(10)` to eliminate theoretical panic vectors.

---

### Final Verdict: **GREEN**

The ONE Sui implementation demonstrates exceptional rigor. It correctly ports battle-tested Liquity-V1 accounting while adhering strictly to Sui's object model, capability system, and Move 2024.beta semantics. All 16 targeted questions pass with zero critical or high-severity findings. The immutability design (`destroy_cap` consuming both caps) is sound, the SP math is properly guarded against overflow and cliff-edge corruption, and the oracle integration uses appropriate belt-and-suspenders validation. The two minor findings are strictly observational/defensive and do not impact protocol safety or fund security.

**Recommendation:** Clear for mainnet deployment. Proceed with the documented 2-tx deploy sequence and ensure deployer discipline between Tx1 and Tx2 as specified.

---

## Our review of the Qwen response

**Cross-check vs Gemini + Grok:** Third independent auditor. All three converge on GREEN verdict. Q1-Q16 verdicts 100% identical across all three.

**Numerical fact-check on Q13:** Qwen quotes `~1.84e27` for `(debt * 1000 / 10000) * 1e9`. Our verification: `(1.84e19 * 1000 / 10000) * 1e9 = 1.84e27` — exact match. More accurate than Gemini's `~2e28` but less tight than our `1.845e37` worst-case (`sp_coll × product_factor`). Conclusion SAFE concurs.

**Two additional findings to document (NOT yet applied, pending user decision):**

### INFO #1 — sp_claim zero-event
- Source confirms: `sp_settle` emit block gated on `pending_one > 0 || pending_coll > 0`
- Observability concern only; indexers can filter zero-value claims off-chain
- Status: PENDING USER DECISION

### LOW #1 — now+10 theoretical overflow
- Source confirms: `assert!(ts <= now + 10, E_STALE)` uses unsigned addition
- Also applies to companion `ts + STALENESS_SECS >= now` (Qwen did not catch)
- Numerical scale: u64::MAX timestamp ≈ 584 billion years from present
- Current unix ≈ 1.777e9s; u64::MAX ≈ 1.845e19s; gap ≈ 1.843e19s ≈ 5.84e11 years
- Age of universe: 1.38e10 years → overflow is ~42× current universe age away
- Status: PENDING USER DECISION

## Accept / reject

**RESPONSE ACCEPTED** as valid R1 audit input. Verdict GREEN reinforces Gemini + Grok conclusions (3/4 auditors GREEN so far).

**Two findings PENDING USER DECISION** — not applied, not rejected. Documented only.
