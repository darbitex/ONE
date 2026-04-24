# Claude 4.7 Adaptive (fresh web session) — ONE Sui R1 Response

**Received:** 2026-04-25
**Submitted:** `AUDIT_R1_SUBMISSION.md` (full)
**Verdict:** **YELLOW** (not GREEN)
**Findings:** 1 MEDIUM (M-01 zombie-inflation via reset-on-empty), 1 LOW (no sealed-gate on entries), 2 INFO

**Significance:** First non-GREEN verdict. Breaks prior 5/5 convergence. User instruction is documentation-only; no code change applied, no rejection issued.

---

## Raw response

# ONE Sui R1 Audit Response

**Auditor:** Independent review
**Scope:** `sources/ONE.move` (~850 lines) as submitted in `AUDIT_R1_SUBMISSION.md`
**Verdict:** 🟡 **YELLOW** — One MEDIUM finding (M-01) and one LOW finding warrant fixes before publish; remainder is GREEN. Once M-01 is patched and a regression test added, this is publish-ready.

---

## Q1–Q16 Answers

**Q1 — Mint-path exhaustion: [OK]**
`coin::mint(&mut reg.treasury, ...)` appears exactly twice, both inside `open_trove` (lines 535–536: `debt - fee` to user + `fee` to fee routing). No `coin::mint`, `coin::from_balance` against `Balance<ONE>` minted from thin air, or any other supply-creating call exists outside `open_trove`. `coin::from_balance` on ONE elsewhere always sources from existing balances (`fee_pool`, `sp_pool`) that themselves were sourced from prior mints or user inputs. TreasuryCap is held inside `Registry` and never exposed; `OriginCap` does not unlock mint. Confirmed exhaustive.

**Q2 — Burn correctness: [OK]**
Conservation: `total_minted = total_burned + circulating + fee_pool.value + sp_pool.value`. Verified per path:
- `close_trove` burns exactly `t.debt` (line 582), trove removed atomically.
- `redeem` splits `fee` then burns `one_in_mut` which now equals `net = one_amt - fee` (lines 622–623).
- `redeem_from_reserve` same pattern (lines 650–651).
- `liquidate` splits `debt` from `sp_pool` and burns (lines 704–705); SP balance invariant maintained because `assert!(reg.total_sp > debt, E_SP_INSUFFICIENT)` ensures the split succeeds.
- `route_fee` always burns 25% of incoming fee; remaining 75% either joins `fee_pool` (SP non-empty) or also burns (SP empty). Both `destroy_zero` calls guarded by `value == 0` checks.

The intentional 0.25%–1% supply-vs-debt gap per cycle (WARNING 4) is a design choice, not a conservation violation.

**Q3 — Balance pool invariants: [OK]**
Traced every state-mutating entry; each invariant holds:
- `treasury_coll == Σ troves[i].collateral`: `open_trove` and `add_collateral` increment both by `coll_amt`; `close_trove` and `redeem` decrement both by the same amount; `liquidate` decrements `treasury_coll` by exactly `total_seize_coll + target_remainder = coll`, and removes the trove (Q4 below confirms the partition).
- `sp_pool.value == total_sp`: `sp_deposit` (+amt both), `sp_withdraw` (−amt both), `liquidate` (−debt both, lockstep on lines 704 and 710). ✓
- `fee_pool` only grows via `route_fee` join (line 447), only drains via `sp_settle` split (line 493). ✓
- `reserve_coll` only grows via `liquidate` (line 715), only drains via `redeem_from_reserve` (line 654). ✓
- `sp_coll_pool` only grows via `liquidate` (line 718), only drains via `sp_settle` (line 497). ✓

**Q4 — Liquidation arithmetic identity: [OK]**
By construction:
```
sp_coll = total_seize_coll - liq_coll - reserve_coll_amt   (line 697)
target_remainder = coll - total_seize_coll                  (line 698)
```
Therefore `liq_coll + reserve_coll_amt + sp_coll + target_remainder = total_seize_coll + (coll - total_seize_coll) = coll` exactly. No drift, no missing unit. Underflow guards: `liq_coll = min(liq_u128, total_seize_coll_u128)` ensures `remaining_u128 >= 0`; `reserve_coll_amt = min(reserve_u128, remaining_u128)` ensures `sp_coll >= 0`; `total_seize_coll = min(total_seize_u128, coll_u128)` ensures `target_remainder >= 0`.

**Q5 — Redemption zombie guard: [OK]**
Two cases analyzed:
- **`net = 0` impossible**: `one_amt >= MIN_DEBT = 1e8`, `fee = one_amt / 100 >= 1e6`, so `net = one_amt - fee >= 99e6 > 0`.
- **`coll_out = 0` possible only at unrealistic prices** (price > 9.9e16, i.e., SUI > $990M): in that case `t.debt -= net` (positive) and `t.collateral -= 0` (unchanged). Post-condition `assert!(t.debt == 0 || t.collateral > 0, E_COLLATERAL)` passes only because the trove's collateral was already > 0 (otherwise the prior assertion `t.collateral >= coll_out` is vacuously true and post-condition still passes since collateral remains > 0). The only way to reduce collateral to 0 with positive debt is via the `t.collateral -= coll_out` line where `coll_out = t.collateral`, in which case post-condition fires E_COLLATERAL. (coll=0, debt>0) is structurally unreachable.

**Q6 — Feed-id check: [OK]**
Move's `vector<u8> ==` is element-wise + length-equal. Empty vector ≠ 32-byte feed ID (length differs). Verified the literal `x"23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744"` matches Pyth Insights' published SUI/USD mainnet feed ID (`0x23d7...5744`) — confirmed via web cross-check. The `0x50c67b3f...266` value seen in some Pyth docs example snippets is the **Sui testnet** Beta-channel ID (snippet uses `hermes-beta.pyth.network`), which is a documentation artifact, not a conflict. The audit code uses the correct mainnet/Stable-channel ID.

**Q7 — Staleness ordering: [OK]**
`pyth::get_price_no_older_than(pi, clock, 60)` aborts inside Pyth if `ts + 60 < now`. The subsequent local `assert!(ts + STALENESS_SECS >= now, E_STALE)` is redundant under current Pyth semantics but defensively protects against any future Pyth-side change that loosens its check. The `assert!(ts <= now + 10, E_STALE)` defends against future-dated Pyth timestamps (Pyth itself does not bound this). No overflow in `ts + STALENESS_SECS` (Unix timestamp + 60 well under u64). Layering is sound.

**Q8 — sp_settle zombie path: [OK for what it covers; see M-01 below for adjacent gap]**
The R2-C01 port is correct: when `initial == 0 || snap_p == 0`, the early-return refreshes `snapshot_product`, `snapshot_index_one`, `snapshot_index_coll` to current values (lines 461–467) before returning, eliminating the stale-snap-on-zero-balance redeposit attack from the Aptos R2 round. `test_zombie_redeposit_no_phantom_reward` exercises this. **However**, see M-01 — the symmetric case where `initial > 0` but the position has been logically zombied by liquidations (effective rounded to 0) WITHOUT the user ever calling settle is NOT covered by this fix and is reachable via the Sui-specific reset-on-empty.

**Q9 — Reset-on-empty safety: [FINDING — see M-01 below]**

**Q10 — OriginCap soulbound: [OK]**
`OriginCap has key` only (no `store`). In Sui, `transfer::public_transfer<T>` requires `T: store`, so `public_transfer(cap, addr)` does not compile. `transfer::transfer<T>` does not require `store` but is restricted to the defining module. Searching the entire ONE source: `OriginCap` is moved exactly twice — once in `init` via `transfer::transfer(OriginCap{...}, sender(ctx))` (line 356) and once in `destroy_cap` via destructure-and-delete (lines 374–375). No public function takes `OriginCap` and re-transfers it. No vector/table can hold it (no `store`). Soulbound to deployer until `destroy_cap` consumes it.

**Q11 — destroy_cap atomicity: [OK]**
Move transactions are atomic — any abort reverts ALL state changes. If `package::make_immutable(upgrade)` aborts (which it does not under documented Sui semantics, but hypothetically), the prior `object::delete(id)` is rolled back along with everything else. `OriginCap` is restored. Re-entry is then possible. Reasoning is correct.

**Q12 — Coin registry 2-step gotcha: [NEEDS_INFO, but likely OK]**
The `coin_registry::new_currency_with_otw` + `finalize_and_delete_metadata_cap` (Tx 1) + `finalize_registration` (Tx 2) flow is the Sui ≥1.48 documented pattern. Between Tx 1 and Tx 2, `Currency<ONE>` is in the CoinRegistry's TTO mailbox; `finalize_registration` is permissionless (anyone can call it), but it only promotes the existing `Currency<ONE>` to a shared object — it cannot substitute a malicious variant because the OTW guarantee means no `ONE` type instance exists outside `init`. So front-running `finalize_registration` is harmless (it does what your deploy script would have done). I would recommend the deploy script bundle both Tx 2 calls in a single PTB (as your docs describe), but a front-runner who calls `finalize_registration` between txs causes no security harm — just one fewer call in your PTB. Worth a final read of the current `coin_registry.move` source on the pinned framework rev to confirm there is no other entrypoint that interacts with the in-flight `Currency<ONE>` before `finalize_registration`. Marking NEEDS_INFO pending that source-level confirmation against your pinned framework version.

**Q13 — u128 overflow margins: [OK with caveat]**
- `(debt as u128) * LIQ_BONUS_BPS / 10000` ≤ `1.84e19 * 1000 = 1.84e22`. Fine.
- `total_seize_usd * SUI_SCALE` ≤ `2e19 * 1e9 = 2e28`. Fine.
- `(coll as u128) * price / SUI_SCALE` is the only one that can theoretically overflow: if `abs_e = 0` (whole-dollar Pyth price, atypical for crypto) AND `coll = u64::max` (~1.84e19), then `coll * price` could reach `1.84e19 * 9.2e26 = 1.7e46`, exceeding u128 max (3.4e38). **Practically unreachable** because the entire SUI supply is bounded at 10 billion (~1e19 raw units, approaching but not reaching u64 max), and Pyth crypto feeds use exponents around -8. Worth a comment in `price_8dec` noting the bounded-input assumption, but I do not require a code change.

**Q14 — conf check semantics: [OK]**
`(conf as u128) * 10000 <= (MAX_CONF_BPS as u128) * raw` — assertion **passes** when `conf/raw <= MAX_CONF_BPS/10000 = 0.02 = 2%`. Direction correct (rejects when conf is too wide). Edge case `raw == 0` makes RHS 0 and would force `conf == 0`, but `assert!(raw > 0, E_PRICE_ZERO)` on line 408 fires earlier. Ordering correct.

**Q15 — Coin<ONE> inflation via coin_registry: [OK]**
By Sui's coin model, only TreasuryCap<T> can mint Coin<T>. `coin_registry` manages metadata and the shared Currency object; it does not expose any mint primitive that bypasses TreasuryCap. Your TreasuryCap is sealed inside the shared Registry and only `open_trove` accesses `&mut reg.treasury` for mint (Q1 confirmed). No coin_registry-mediated inflation path.

**Q16 — Move 2024.beta semantics: [OK]**
The patterns used — block-scoped immutable borrow that returns extracted scalars (`sp_settle` lines 457–460), block-scoped mutable borrow that returns a copyable bool (`sp_withdraw` lines 780–785), `let mut` rebinding for `Coin` in close/redeem paths — are all stable in 2024.beta and work the same in 2024.alpha. Borrows release at block end, allowing subsequent `&mut reg.X` accesses without conflict. The field-level borrow split via `&mut reg.treasury` (TreasuryCap<ONE>) and `&mut reg.sp_pool` (Balance<ONE>) within the same function is fine because `Registry` field-level borrows are tracked per-field by the borrow checker. No subtle 2024.beta-specific issue identified.

---

## Findings

### M-01 — MEDIUM — Reset-on-empty + stale-snap zombie inflation in `sp_deposit`/`sp_settle`

**Location:** `sp_deposit` line 752 (`if (reg.total_sp == 0) { reg.product_factor = PRECISION; }`) interacting with `sp_settle` line 461 zombie check (`if (snap_p == 0 || initial == 0)`).

**Description.** The R2-C01 port from Aptos correctly handles the case where `sp_settle` previously zeroed a user's `pos.initial_balance` and would otherwise leave snaps stale on redeposit. But the symmetric case is uncovered: a user (M) who deposited at a low product_factor (`snap_M < PRECISION`) and whose effective balance has been driven to 0 by subsequent liquidations, but who has **never called `sp_settle`** — so `pos.initial_balance` remains at the original positive deposit value while snaps remain at the original low values.

If `total_sp` later reaches exactly 0 (cleanly drained without dust), the next `sp_deposit` triggers the reset to `PRECISION`. When the zombie M then deposits any positive amount, `sp_settle` runs:
- `snap_p = old_low_value`, `initial = original_deposit > 0` → zombie branch **NOT** taken.
- `raw_bal = initial * PRECISION / snap_p` ← inflation = `PRECISION / snap_p` ≥ 2.
- `pos.initial_balance` is rewritten to the inflated value. M can now withdraw more than they deposited.
- The same inflation applies to `pending_one` from `(reward_index_one - snap_i_one_STALE) * initial / snap_p_STALE`.

I built a Python simulation matching the on-chain math and confirmed the inflation step works exactly as described. The remaining question is reachability of the `total_sp == 0` precondition — see "Exploitability" below.

**Exploitability.** Practically constrained, but not zero:
- Cliff guard caps `new_p >= MIN_P_THRESHOLD = 1e9`, so per-address inflation factor ≤ `PRECISION / MIN_P_THRESHOLD = 1e9` and per-address theft ≤ ~10 ONE.
- The dominant friction is **dust**: liquidation P-update `new_p = P * (T-d) / T` rounds down, and per-user `sp_settle` rounds down when computing effective balance. After any liquidation with `gcd(T-d, T) < T`, `total_sp` ends up strictly greater than the sum of users' settled effective balances. A zombie with non-zero `pos.initial` cannot withdraw their (rounded-to-zero) effective, and the dust prevents `total_sp` from reaching exactly 0 via the remaining clean withdrawals. My simulations across multiple scenarios show that natural dust accumulation usually leaves `total_sp ∈ {1, 2, ...}` rather than 0.
- However, this is a **statistical** defense, not a guaranteed one. Specific liquidation amount sequences (which the attacker can partially influence by being the unhealthy-trove owner) can produce zero-dust outcomes. Over the lifetime of an immutable protocol, the chance of this combination occurring opportunistically is non-trivial.
- Per-incident impact on victims: `pos.initial_sum > total_sp` after the inflated zombie deposits, so when the next legitimate depositor C tries to withdraw their full balance, `total_sp` underflows or `sp_pool` split fails. C is forced to withdraw less than their deposit, with the difference captured by M.

Given (a) immutability — no patch is possible post-deploy, (b) the Aptos R2-C01 fix philosophy (eliminate the entire zombie-snap-staleness class, not just the variant exercised in the test), and (c) the simplicity of the fix, I rate this **MEDIUM** rather than LOW.

**Recommended fix.** Track an epoch counter that increments on each reset, and treat any position whose snap pre-dates the current epoch as a zombie. Concrete sketch:

```move
public struct Registry has key {
    // ... existing fields ...
    sp_epoch: u64,    // increments on each reset-on-empty
}

public struct SP has store, drop {
    initial_balance: u64,
    snapshot_product: u128,
    snapshot_index_one: u128,
    snapshot_index_coll: u128,
    snapshot_epoch: u64,    // epoch at last settle/deposit
}

// In sp_deposit, replace the bare reset with:
if (reg.total_sp == 0) {
    reg.product_factor = PRECISION;
    reg.sp_epoch = reg.sp_epoch + 1;
};

// In sp_settle, extend the zombie check:
if (snap_p == 0 || initial == 0 || pos.snapshot_epoch < reg.sp_epoch) {
    pos.snapshot_product = r.product_factor;
    pos.snapshot_index_one = r.reward_index_one;
    pos.snapshot_index_coll = r.reward_index_coll;
    pos.snapshot_epoch = r.sp_epoch;
    return
};

// And update snapshot_epoch in the normal settle path and on new-position creation.
```

This is O(1) per call, schema-additive, and makes any cross-reset interaction provably reset to a fresh state with zero pending rewards.

**Regression test.** Add `test_zombie_redeposit_after_reset_no_inflation`:
1. A deposits clean amount at PRECISION; liquidation halves P.
2. M deposits 1 raw at the lower P (snap_M < PRECISION, M never settles).
3. Further liquidations drive M's effective to 0 while leaving A withdrawable.
4. A withdraws cleanly; total_sp reaches 0 (force via `test_set_sp_position` if dust prevents).
5. C deposits → reset triggers.
6. M re-deposits → assert M's `pos.initial_balance == amt` (the new deposit, not inflated).
7. M withdraws `amt` → success; M cannot withdraw more.

---

### L-01 — LOW — No `assert!(reg.sealed, ...)` on user-facing entries

**Location:** All public entry functions (`open_trove`, `redeem`, `redeem_from_reserve`, `liquidate`, `sp_deposit`, `sp_withdraw`, `sp_claim`, `add_collateral`, `close_trove`).

**Description.** Between Tx 1 (publish) and Tx 2 (`destroy_cap`), the protocol is fully callable. Documentation says "users should not interact pre-seal," but nothing on-chain enforces this. A premature interaction during the deploy window is operationally awkward (the deployer technically retains UpgradeCap and could change the package logic before sealing, which is a deployer-trust matter), but more concretely, a user who interacts pre-seal might create a trove or SP position whose state assumptions don't match what the eventual sealed code guarantees.

**Recommendation.** Add `assert!(reg.sealed, E_NOT_SEALED)` to the oracle-dependent and value-creating entries: `open_trove`, `redeem`, `redeem_from_reserve`, `liquidate`, `sp_deposit`. Leave `close_trove`, `add_collateral`, `sp_withdraw`, `sp_claim` open as escape hatches (they are post-seal robust either way; pre-seal there is nothing to escape from). Cost: one storage read per entry; benefit: deploy-window safety net plus "cannot use until sealed" becomes a code-enforced invariant rather than a documentation request.

---

### I-01 — INFO — 60s Pyth staleness window enables minor MEV
Pyth pull-based updates let a caller submit any signed price within the staleness window. With `STALENESS_SECS = 60`, an opportunistic actor in a fast-moving SUI/USD market can choose the older-but-valid price within that window for liquidation, redemption, or open_trove timing. This is intrinsic to pull oracles and the chosen window is reasonable; flagging only because the audit submission asks for any oracle-MEV thoughts. No action recommended unless you want a tighter window (e.g., 30s) at the cost of more frequent abort-and-retry from honest users.

### I-02 — INFO — Test coverage gap on oracle-dependent paths
As your submission already notes, `open_trove`, `redeem`, `liquidate`, `redeem_from_reserve` are not unit-tested due to `PriceInfoObject` construction difficulty in `test_scenario`. This is a real risk: the most exploit-relevant paths (mint, burn from SP, liquidation arithmetic) are exercised only via `#[test_only]` helpers that bypass oracle. **Strongly recommend** a testnet integration test before mainnet that exercises a full open → liquidate → SP-claim → close cycle with real Pyth `PriceInfoObject` updates. Many Sui-specific bugs (PTB ordering, shared-object versioning under contention, Pyth integration glitches) only surface against the live framework.

---

## Summary

The submission is high-quality. Math invariants, balance conservation, OriginCap soulbinding, sealing semantics, and oracle defenses are all sound. The one substantive finding (M-01) is a Sui-specific consequence of the reset-on-empty mechanism and is constrained but not eliminated by the existing R2-C01 port — fixing it requires the small epoch-counter change above. With M-01 patched + regression test added + L-01 sealed-entry guards added + a testnet integration test of the oracle-dependent paths, this clears for publish.

Happy to re-review the patch when ready.

---

## Documentation notes (no action taken)

**Status:** DOCUMENTED only per user instruction "jangan buat apa apa dulu, hanya kumpulkan dan dokumentasikan hasil audit". No code changes, no acceptance/rejection, no additional investigation.

**Cross-auditor comparison after 6 audits:**
- Gemini 3.1 Pro, Grok, DeepSeek: GREEN, 0 findings
- Cerebras Qwen3: GREEN, 1 INFO (sp_claim zero-event) + 1 LOW (now+10 overflow)
- Kimi: GREEN, 1 INFO (sp_settle saturation dead-code)
- **Claude 4.7 Adaptive (fresh): YELLOW, 1 MEDIUM + 1 LOW + 2 INFO**

**The M-01 finding is NOVEL** — it exists in the composition of two features that were each individually reviewed by the other 5 auditors:
- Q8 (sp_settle zombie): all 5 prior said OK — they checked `initial == 0` branch.
- Q9 (reset-on-empty): all 5 prior said OK — they checked attacker can't exploit the reset itself.
- **Claude's M-01 is the INTERACTION** between these two: a position with `initial > 0` but zombied (effective=0) from prior liquidations, AND the position owner never called settle, AND total_sp reaches 0 cleanly → reset fires → zombie redeposit gets inflation from stale snap_p.

**Claude's own simulation claim:** says dust accumulation usually prevents `total_sp == 0`, making the attack statistically rare but not impossible on a long-running immutable protocol.

**The M-01 fix proposal:** add `sp_epoch` counter that increments on each reset; add `snapshot_epoch` to SP position; treat pre-reset snapshots as zombie in `sp_settle`. O(1) per call, schema-additive.

**This is the first substantive disagreement across 6 auditors.** Requires user decision:
- Accept finding as valid and apply fix (breaks the all-GREEN unanimous narrative)
- Reject finding as non-exploitable in practice (relies on statistical dust argument)
- Deep-dive investigation before deciding (simulate the exact scenario claimed, verify whether dust-free total_sp=0 is reachable)
