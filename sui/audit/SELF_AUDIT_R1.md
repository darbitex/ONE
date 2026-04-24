# ONE Sui v0.1.0 — Self-Audit R1 (Claude, in-session)

**Auditor:** Claude (Opus 4.7, parallel auditor)
**Scope:** Full source `sources/ONE.move` (844 lines) + `Move.toml` + vendored deps (`deps/pyth/`, `deps/wormhole/`) + `tests/ONE_tests.move` (328 lines, 19/19 green).
**Date:** 2026-04-24
**Context:** Fresh-eyes Round-1 audit of the Sui port. Reference implementations: `aptos/sources/ONE.move` (712 lines, R4 GREEN) and `supra/sources/ONE.move` (707 lines, v0.4.0 LIVE + SEALED).

---

## Executive summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 0 |
| LOW | 4 |
| INFO / NIT | 7 |

**Verdict:** GREEN. No logic bugs, no security issues, no blockers for next-round external audit. The port is faithful to the Aptos/Supra reference semantics; the only findings are lint-level cleanup, deprecation warnings from Sui framework evolution, and documentation clarifications around Sui-specific semantics (decimals, error-code numbering, PTB flow).

Key invariants manually verified:
- `treasury_coll.value == Σ troves[i].collateral` across open/add/close/redeem/liquidate.
- `sp_pool.value == total_sp` across deposit/withdraw/liquidation.
- `product_factor` monotonically non-increasing; cliff-freeze at `MIN_P_THRESHOLD`.
- Unit consistency: all SUI math uses `SUI_SCALE = 1e9` (MIST → USD-8dec conversion).
- No partial state on abort: all entry functions perform asserts before any state mutation, except `destroy_cap` where `OriginCap` is deleted before `make_immutable` — but `make_immutable` cannot abort (Sui framework guarantee), and Move tx atomicity would revert anyway.

Collateral-distribution math in `liquidate` traced end-to-end:
- `seized` starts at `total_seize_coll`; reserve takes `reserve_coll_amt`, sp takes `sp_coll`, liquidator receives the residual = `liq_coll`. Arithmetic identity holds: `liq_coll + reserve_coll_amt + sp_coll == total_seize_coll`.
- `target_remainder = coll - total_seize_coll` is split separately from `treasury_coll`. Invariant: both splits sum to the trove's `coll`, matching the treasury deduction.

---

## LOW

### L-1. `public entry` on `public fun` is redundant (lint W99010)

**Locations:** `ONE.move:181, 367, 555, 608, 618, 630, 639, 651, 662, 673` (10 occurrences).

**Issue:** In Move 2024.beta / Sui, `public` functions are already PTB-callable. Adding `entry` on a `public` function has no effect (the Sui lint explicitly states this). The compiler emits 10 W99010 warnings.

**Impact:** Zero runtime behavior difference. Lint noise. External auditors will note.

**Recommendation:** Drop `entry` on all `public entry fun`. Behavior is identical.

**Confidence:** High.

---

### L-2. `sui::coin::create_currency` is deprecated (W04037) — MIGRATED

**Location:** `ONE.move:140-158` (post-fix).

**Original issue:** Sui framework ≥ mainnet-v1.68.1 deprecates `coin::create_currency` in favor of `coin_registry::new_currency_with_otw`. Warning fired during build.

**Resolution (user-requested 2026-04-24):** Migrated to the new API. User's rationale: coin must be future-proof for discoverability by wallets/explorers that query the global `CoinRegistry` shared object.

**New init flow:**
```move
let (initializer, treasury) = coin_registry::new_currency_with_otw<ONE>(
    witness, 8,
    string::utf8(b"ONE"), string::utf8(b"1"),
    string::utf8(b"Immutable CDP-backed stablecoin on Sui (SUI-collateralized)"),
    string::utf8(b""),
    ctx,
);
coin_registry::finalize_and_delete_metadata_cap(initializer, ctx);
// treasury stored in Registry; Currency<ONE> TTO'd to CoinRegistry address
```

**`finalize_and_delete_metadata_cap`** consumes the MetadataCap — metadata (name/symbol/decimals/description/icon) becomes permanently immutable, equivalent to the `public_freeze_object(metadata)` guarantee in the old API.

**Two-step deploy consequence:** After publish, `Currency<ONE>` sits as a pending Receiving at `object::sui_coin_registry_address()`. Someone must call `coin_registry::finalize_registration(&mut CoinRegistry, Receiving<Currency<ONE>>, ctx)` to promote it to a shared object. This is permissionless ("Can be performed by anyone") — deploy scripts bundle it into the same PTB as `destroy_cap`:

1. **Tx 1**: `sui client publish` → init runs → Currency<ONE> TTO to registry addr, OriginCap + UpgradeCap + Registry returned to deployer.
2. **Tx 2 (single PTB)**: `coin_registry::finalize_registration` + `ONE::destroy_cap` → coin finalized in global registry, package made immutable, `reg.sealed = true`.

**Build status:** W04037 deprecated-usage warning resolved. 19/19 tests still green.

**Confidence:** High.

---

### L-3. Redundant `use` imports in ONE.move (W02021)

**Location:** `ONE.move:11` (`use std::option`), `17` (`use sui::object::{Self, UID}`), `21` (`use sui::transfer`), `22` (`use sui::tx_context::{Self, TxContext}`).

**Issue:** Move 2024 default-imports `std::option`, `sui::object::{Self,UID}`, `sui::transfer`, `sui::tx_context::{Self,TxContext}` automatically. Explicit `use` statements are redundant.

**Impact:** Lint warnings only. No runtime effect.

**Recommendation:** Drop the redundant `use` lines. Cosmetic cleanup.

**Confidence:** High.

---

### L-4. `test_utils::destroy` is deprecated in favor of `std::unit_test::destroy`

**Location:** `tests/ONE_tests.move:100, 123` (2 occurrences).

**Issue:** Sui framework deprecated `test_utils::destroy`; recommended replacement is `std::unit_test::destroy`.

**Impact:** Tests pass. Cosmetic.

**Recommendation:** Swap when convenient, or accept the warning.

**Confidence:** High.

---

## INFO / NIT

### I-1. Error-code numbering diverges from Aptos/Supra at slot 17

**Aptos/Supra:** slot 17 = `E_NOT_ORIGIN`, slot 18 = `E_CAP_GONE`.
**Sui:** slot 17 = `E_WRONG_FEED`, slot 18 = `E_SEALED`.

**Rationale:** On Sui, possession of `OriginCap` by-value IS the authorization check — there's no separate "not origin" path. Meanwhile Sui needs an explicit check that the caller passed the correct SUI/USD `PriceInfoObject`, since Sui PTBs can supply any object of the right type — hence `E_WRONG_FEED` (code 17).

**Impact:** Off-chain tooling that maps numeric codes to human-readable errors must have per-chain mapping tables. The frontend already handles this via TypeScript enums scoped per chain, so no runtime issue, but worth documenting.

**Recommendation:** Add a `docs/ERROR_CODES.md` (or a header comment block) explicitly enumerating the Sui error codes and calling out the Aptos/Supra divergence at slots 17 and 18.

**Confidence:** High.

---

### I-2. SUI is 9-decimal; APT/SUPRA are 8-decimal — frontends must track `SUI_SCALE`

**Location:** `ONE.move:47` (`const SUI_SCALE: u128 = 1_000_000_000`).

**Issue:** All collateral conversions use `SUI_SCALE = 1e9`. A frontend that reuses Aptos math (which uses `1e8`) would produce prices off by 10×. The Sui module on-chain is correct; the risk is off-chain.

**Impact:** Off-chain only. Already documented in WARNING clause (9) ("net times 1e9 over price SUI"). Frontend/SDK must use correct divisor.

**Recommendation:** When wiring the frontend, unit-test the price conversion using a known SUI price (e.g., $3.14 → 3_14000000 in 8dec) and verify user-displayed collateral in SUI matches. See also `feedback_decimals_verification.md`.

**Confidence:** High.

---

### I-3. `price_8dec` applies defense-in-depth staleness check redundantly with Pyth's own

**Location:** `ONE.move:212-215`.

**Issue:** `pyth::get_price_no_older_than(pi, clock, STALENESS_SECS)` already aborts if staler than `STALENESS_SECS`. Our subsequent `assert!(ts + STALENESS_SECS >= now, E_STALE)` is therefore never reached on the normal path — Pyth aborts first with its own error code.

**Impact:** Defense-in-depth: if Pyth's semantics change in a future upgrade (and with Pyth Sui being governance-upgradable — see `feedback_pyth_sui_not_immutable.md` — this IS a realistic concern), our own check still fires. This is intentional and matches the Aptos M-2 recommendation (option c).

**Recommendation:** Keep. Optionally add an inline `// belt-and-suspenders: Pyth handles staleness, but we re-check in case its semantics drift under governance upgrade` comment for future auditors.

**Confidence:** High.

---

### I-4. `OriginCap` is transferable (not soulbound) before seal

**Location:** `ONE.move:108` (`public struct OriginCap has key { id: UID }`).

**Issue:** `OriginCap` has `key` only (no `store`), so `transfer::public_transfer` would not compile — users cannot transfer it via the public API. BUT `transfer::transfer` works within the defining module if we had a wrapper. We don't expose one, so effectively the publisher cannot forward OriginCap to another address through our module.

However, Sui's built-in `sui::transfer::transfer` can be invoked from any PTB as long as the object has `key`. **Let me verify**: the actual restriction is that non-`store` objects can only be transferred within their defining module. So a user CANNOT call `sui::transfer::transfer` on `OriginCap` from an arbitrary PTB (the framework enforces this). `OriginCap` is effectively soulbound to the deployer address.

Verified: `OriginCap` cannot be re-sent from outside `ONE::ONE` module. Post-publish, only the deployer can call `destroy_cap`. Good.

**Recommendation:** No code change. Worth a one-line comment on the struct declaration: `// Soulbound: `key`-only, no external transfer path.`

**Confidence:** High (after verification).

---

### I-5. Mainnet publish-then-seal should be a single PTB

**Location:** `deploy-scripts/` (empty — pending).

**Issue:** Between publish and `destroy_cap`, the package is upgradeable by the deployer (they hold `UpgradeCap`). Any user calling into an unsealed package takes on a trust assumption. Mitigation: bundle publish + bootstrap tx + destroy_cap into a single PTB so the package is NEVER in an "unsealed, visible to users" state.

However — Sui PTBs cannot both publish a package AND call a function in that newly-published package in the same tx (the `init` runs atomically with publish, but subsequent calls need separate txs because the new package address isn't known until the publish tx commits). So true single-PTB is not possible.

**Realistic flow:**
1. Tx 1: publish. Sui assigns a package ID; `init` runs; `Registry` is shared; `OriginCap` + `UpgradeCap` go to deployer.
2. Tx 2: deployer immediately calls `destroy_cap(origin, &mut reg, upgrade, &clock, ctx)`. Package becomes immutable.

The window between tx 1 and tx 2 is the only unsafe period. Deployer should script this end-to-end with no user announcements until tx 2 is confirmed.

**Recommendation:** Deploy script must automate tx 2 immediately after tx 1 commits. Document in `deploy-scripts/README.md` that users should not interact until `is_sealed(&reg) == true`.

**Confidence:** High.

---

### I-6. Test coverage does not exercise oracle-dependent paths (inherited from Aptos)

**Location:** `tests/ONE_tests.move` (entire file).

**Issue:** All 19 tests exercise internal math via `#[test_only]` helpers (`test_create_sp_position`, `test_simulate_liquidation`, etc.) — same pattern as Aptos. Oracle-dependent entries (`open_trove`, `redeem`, `liquidate`, `redeem_from_reserve`) are NOT integration-tested in the unit test suite because mocking `PriceInfoObject` from within our test module is nontrivial (the Pyth module gates construction).

**Impact:** Unit tests cover the math; integration tests will be needed on testnet. This is a known gap inherited from the Aptos reference. External audit rounds covered the Aptos oracle surface by inspection.

**Recommendation:** Before mainnet, run a testnet integration test that:
1. Funds a Sui testnet wallet.
2. Updates the SUI/USD `PriceInfoObject` via Pyth Hermes.
3. Executes `open_trove → sp_deposit → liquidate → sp_claim` end-to-end.
4. Asserts balance deltas match expected math.

**Confidence:** High.

---

### I-7. No test for `E_WRONG_FEED` path

**Location:** `tests/ONE_tests.move` (absence).

**Issue:** Our new `E_WRONG_FEED` assertion (feed-id mismatch inside `price_8dec`) has no unit test. Would require mocking a `PriceInfoObject` with a different feed id, which is not trivial.

**Impact:** The assertion is simple (byte-vector equality), so risk is low. But an audit would flag the missing case.

**Recommendation:** Either add a `#[test_only]` helper `test_assert_feed_check(feed_bytes: vector<u8>)` that runs the comparison in isolation, OR accept as known gap covered by integration testing on testnet.

**Confidence:** High.

---

## Per-function trace (ABI / args / math / edges / events)

### `init(witness: ONE, ctx)`
- OTW `ONE {}` consumed by `coin::create_currency`. ✓
- `metadata` frozen via `public_freeze_object` → immutable name/symbol/decimals. ✓
- `Registry` shared; `OriginCap` transferred to `tx_context::sender(ctx)` (= publisher). ✓
- Initial state: all pools empty, tables empty, `product_factor = PRECISION`, `sealed = false`. ✓

### `destroy_cap(origin, reg, upgrade, clock, ctx)`
- Abort guard `!reg.sealed` before any mutation. ✓
- `OriginCap.id` deleted via `object::delete`. ✓
- `package::make_immutable(upgrade)` consumes `UpgradeCap`. Package is permanently non-upgradeable. ✓
- `reg.sealed = true`. Event emitted. ✓
- Atomicity: if any step aborted the whole tx reverts. `make_immutable` cannot abort by design.

### `price_8dec(pi, clock)`
- Feed-id check: `price_identifier::get_bytes(&id) == SUI_USD_PYTH_FEED` (32-byte comparison). ✓
- Staleness (Pyth + our own belt-and-suspenders). ✓
- Expo must be negative (Pyth convention for prices). ✓
- Price must be positive. ✓
- Confidence ≤ 2% of price (`MAX_CONF_BPS = 200`). ✓
- Magnitude normalized to 8 decimals. Final `result > 0` check. ✓
- Overflow: with abs_e ≤ 18, `pow10(abs_e - 8) ≤ 1e10`; product `raw * pow10(8 - abs_e)` stays within u128 for any realistic Pyth price.

### `route_fee(r, fee_bal, ctx)`
- 25% burn, 75% either burn (if no SP depositors) or join to `fee_pool` + increment `reward_index_one`. ✓
- Zero-amount paths destroy the zero balance cleanly (`balance::destroy_zero`). ✓
- Event `FeeBurned` emitted only when `burn_amt > 0`. ✓

### `sp_settle(r, u, ctx)`
- Scoped borrows release `pos` before re-borrowing mutably. ✓
- Saturation at `u64::MAX` for `pending_one` / `pending_coll` / `new_balance`. ✓
- `RewardSaturated` event on saturation. ✓
- Zombie-reset path (`snap_p == 0 || initial == 0`) refreshes snaps to prevent phantom rewards. ✓ (R2-C01 fix ported; covered by `test_zombie_redeposit_no_phantom_reward`.)
- Balance splits from `fee_pool` and `sp_coll_pool` transfer to `u` via `public_transfer`. ✓

### `open_trove(reg, coll, debt, pi, clock, ctx): Coin<ONE>`
- `debt >= MIN_DEBT` gate. ✓
- Oracle read upfront. ✓
- MCR check: `coll_usd * 10000 >= 20000 * debt_u128` (200% CR required). ✓
- Collateral joins `treasury_coll` via `coin::into_balance`. ✓
- Mint `debt - fee` to user (returned as Coin<ONE>), mint `fee` routed. ✓
- Trove add-or-update path. ✓
- `total_debt += debt`. Event emitted. ✓
- Zero `coll_amt`: effectively aborts via MCR check (0 ≥ 20000 × debt only if debt=0, but debt ≥ MIN_DEBT). ✓

### `add_collateral(reg, coll, ctx)` (entry)
- `amt > 0`. ✓
- Trove must exist (`E_TROVE`). ✓
- Collateral joins treasury, trove field incremented. ✓
- No oracle touched — oracle-free escape hatch preserved. ✓

### `close_trove(reg, one_in, ctx): Coin<SUI>`
- Trove must exist. ✓
- Remove trove (destructure to `(collateral, debt)`). ✓
- Burn exactly `debt` ONE (from `one_in`), return excess to user, destroy-zero if no excess. ✓
- Edge case: `debt == 0` → skip burn, return `one_in` verbatim. ✓
- Edge case: `coll == 0` → `balance::split(&mut treasury_coll, 0)` yields zero Balance → zero `Coin<SUI>`. ✓
- `total_debt -= debt`. Event emitted. ✓
- No oracle — preserved escape hatch. ✓

### `redeem(reg, one_in, target, pi, clock, ctx): Coin<SUI>`
- `one_amt >= MIN_DEBT`. ✓
- Target trove exists. ✓
- Oracle read, fee = 1%. ✓
- `coll_out = net * 1e9 / price` (u128 math, cast to u64 — aborts on u64 overflow in extreme-low-price regimes, see WARNING clause 7). ✓
- Trove mutation: `t.debt -= net`, `t.collateral -= coll_out`. ✓
- Post-invariants: no dust debt, no (coll=0, debt>0). ✓
- Burn `net`, route fee. ✓
- `total_debt -= net`. Event, return collateral. ✓

### `redeem_from_reserve(reg, one_in, pi, clock, ctx): Coin<SUI>`
- Same oracle + fee + coll_out math. ✓
- `balance::value(&reserve_coll) >= coll_out` pre-check. ✓
- Burn `net`, route fee. ✓
- **Deliberate asymmetry**: does NOT decrement `total_debt` (no trove burned). Inline comment explains the reserve-drain mechanic. ✓

### `liquidate(reg, target, pi, clock, ctx): Coin<SUI>`
- Target exists. ✓
- Oracle read. ✓
- Health gate: `coll_usd * 10000 < 15000 * debt_u128` (CR < 150%, strict). ✓
- SP sufficiency: `total_sp > debt` (strict — strict prevents `new_p = 0`). ✓
- Cliff guard: `new_p >= 1e9`. ✓
- Bonus + share computations using u128. ✓
- Seize caps: `total_seize_coll ≤ coll`, `liq_coll ≤ total_seize_coll`, `reserve_coll_amt ≤ remaining`. ✓
- Arithmetic identity: `liq_coll + reserve_coll_amt + sp_coll == total_seize_coll`. ✓
- Trove removed; `total_debt -= debt`. ✓
- Burn `debt` ONE from `sp_pool`. ✓
- Reward index + product factor update using **old** `product_factor` (pre-mutation) — correct Liquity V1 math. ✓
- Collateral splits: reserve → `reserve_coll`, SP → `sp_coll_pool`, target_remainder → target address, liquidator → returned. ✓
- `Liquidated` event includes all distribution fields. ✓

### `sp_deposit(reg, one_in, ctx)` (entry)
- `amt > 0` gate. ✓
- Join to `sp_pool` BEFORE computing reset-on-empty flag — order matters: `total_sp` check sees pre-deposit count. ✓
- Settle existing position (if any) before augmenting `initial_balance`. ✓
- Create new position with current `product_factor` + `reward_index_*` snaps. ✓
- `total_sp += amt`. Event emitted. ✓

### `sp_withdraw(reg, amt, ctx): Coin<ONE>`
- Gate: `amt > 0`, position exists. ✓
- Settle first (user claims outstanding rewards, `initial_balance` updated to effective). ✓
- Deduct `amt` from `initial_balance` (scoped borrow). ✓
- `total_sp -= amt`. Split `amt` from `sp_pool`. ✓
- Remove position if `initial_balance == 0`. ✓
- Event emitted. ✓

### `sp_claim(reg, ctx)` (entry)
- Position must exist. ✓
- `sp_settle` transfers accumulated rewards (ONE + SUI) to sender. ✓

---

## Invariants

1. **Collateral conservation:** `treasury_coll.value + reserve_coll.value + sp_coll_pool.value == Σ_troves(coll_i) + Σ_seized_coll_post_liquidation`.
   - `treasury_coll` holds sum of live troves' collateral.
   - `reserve_coll` grows only from liquidation reserve shares and is drained only by `redeem_from_reserve`.
   - `sp_coll_pool` holds SP-owned SUI (post-liquidation), drained only by `sp_settle` transfers to depositors.
   - No collateral leaves the Registry except via explicit user-receive paths (close, redeem, liquidate, sp_settle, redeem_from_reserve).

2. **ONE conservation (mod burn):** Mint events (`open_trove`) + user-passed-in (redeem/close/sp_deposit) minus burn events (close, redeem, liquidate SP-side, fee burn) == circulating supply + `sp_pool.value` + `fee_pool.value`. All via `TreasuryCap<ONE>` supply counter.

3. **SP accounting:** `sp_pool.value == total_sp`, and `Σ_users(initial_i * current_P / snap_P_i) == total_sp` (after all positions settled).

4. **Product factor monotonicity:** `product_factor` never increases except via the reset-on-empty path (`total_sp == 0` in `sp_deposit`).

5. **Seal one-way:** `sealed: false → true` only via `destroy_cap`. No reset path. Enforced by `E_SEALED` abort.

All verified by code inspection.

---

## Fix plan before next audit round

1. **[Applied]** Drop `entry` keyword from all `public entry fun` (L-1). 10 occurrences.
2. **[Applied]** Migrate `coin::create_currency` → `coin_registry::new_currency_with_otw` + `finalize_and_delete_metadata_cap` (L-2). Deploy flow now requires a `finalize_registration` call bundled with `destroy_cap` in Tx 2.
3. **[Applied]** Drop redundant `use` imports in `ONE.move` (L-3). 4 lines.
4. **[Applied]** Swap `test_utils::destroy` → `std::unit_test::destroy` in tests (L-4). 2 occurrences.
5. **[Document]** Add `docs/ERROR_CODES.md` enumerating per-chain numbering divergence (I-1).
6. **[Document]** Add `deploy-scripts/README.md` specifying the two-tx publish → finalize+seal flow (I-5).
7. **[Defer to integration]** E_WRONG_FEED test + full oracle-path integration test on testnet (I-6, I-7).

All 4 LOW items applied; 19/19 tests still green. Package is ready for external audit round R2 (Gemini 3 / Grok / Cerebras Qwen3).

---

## Cross-refs

- **Aptos R1 self-audit:** `aptos/audit/self_audit_R1_claude.md` (3 MEDIUM, 4 LOW, 5 INFO — mostly nomenclature).
- **Aptos R4 post-mainnet audit:** `aptos_one_v013_audit_state.md` — R4 GREEN.
- **Supra R1 submission:** `supra/audit/AUDIT_R1_SUBMISSION.md`.
- **Pyth Sui risk notes:** `feedback_pyth_sui_not_immutable.md` (WARNING clause 8 rationale).
- **Decimals discipline:** `feedback_decimals_verification.md` (I-2 rationale).
- **Deploy SOP:** `feedback_mainnet_deploy_sop.md` (1/5 → publish → smoke → freeze → 3/5, adapted for Sui seal-by-UpgradeCap).
