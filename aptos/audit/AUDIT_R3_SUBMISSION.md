# ONE Stablecoin — Round 3 Audit Submission

**Version:** v0.1.2 (post R2 fix batch)
**Chain:** Aptos mainnet (Move 2)
**Philosophy:** Immutable post-`destroy_cap`. Real funds at stake.
**Status:** R1 (8 auditors) → fixes applied. R2 (1 auditor, Claude fresh) → 1 critical + 1 medium + 1 low surfaced and fixed. Supra v0.3.0 fork deprecated publicly for same bugs (unpatchable via null-auth). This R3 round goes to Gemini 3.1 + Claude fresh against the hardened v0.1.2.

---

## R3 ask

Review the **3 R2 fixes** applied on top of the R1-hardened v0.1.1 source.

1. **Validate each R2 fix is correct and regression-free.** The critical one (C-01 snapshot refresh in `sp_settle`) is load-bearing — cross-check that the refresh does not enable a new path to phantom rewards via a different angle.
2. **Weigh in on 2 remaining open design questions** (see §2). Both were raised in R1 and not yet decided unanimously.
3. **Fresh findings** against the patched code.
4. Final verdict: **GREEN / NEEDS FIX / NOT READY**.

Do not re-litigate items validated in prior rounds. Skip Liquity-P math, FA handling, fee routing unless you see a NEW regression from the R2 patches.

A regression test `test_zombie_redeposit_no_phantom_reward` is included (§3 tests). It was sanity-checked: reverting the C-01 fix makes the test fail at the expected assertion; restoring the fix passes. 20/20 tests pass on v0.1.2.

---

## §1. R2 fix batch (applied in v0.1.2)

All 3 fixes were surfaced by Claude fresh web session against v0.1.1 and applied verbatim as recommended. The patched source is in §3.

| # | Origin | Severity | Location | Change |
|---|---|---|---|---|
| R2-C01 | Claude R2 C-01 | **CRITICAL** | `sp_settle` line 228–233 | Early-return branch now refreshes `pos.snapshot_product` / `snapshot_index_one` / `snapshot_index_coll` to current registry values before returning. Prevents phantom reward extraction when a zombie position (initial=0) is re-seeded via `sp_deposit` — the stale snapshots would otherwise pair with a fresh `initial_balance` and inflate the next `pending_one` by `Δindex × new_initial / stale_snap_p`. |
| R2-M01 | Claude R2 M-01 | **MEDIUM** | `redeem_impl` line 340 | Post-update assertion: `assert!(t.debt == 0 || t.collateral > 0, E_COLLATERAL);`. Prevents redemptions from creating `(coll=0, debt>0)` troves that cannot be closed (zero-amount FA withdraw aborts in `close_impl`) nor liquidated (same abort). Attacker was able to brick neighbor troves for 1% fee, polluting `total_debt` permanently. |
| R2-L01 | Claude R2 L-01 | **LOW** | WARNING const line 62 (limitation 3) | Corrected nominal liquidator/reserve share from "25% of debt value" to "2.5% of debt value, being 25% of the 10% liquidation bonus". Factor-of-10 mislabel. On-chain immutable text readable by frontends. |

### R2-C01 validation trace (for reviewer cross-check)

Attack walkthrough on v0.1.1 (unpatched):
1. Attacker deposits 1 raw unit of ONE. Position snapshot: `(initial=1, snap_p=1e18, snap_i_one=0, snap_i_coll=0)`.
2. Unrelated liquidations decay `product_factor` to e.g. `P_t ≈ 5e17`. Fees routed during this window grow `reward_index_one` to `I_t`.
3. Attacker calls `sp_claim`. Since `initial=1 > 0`, `sp_settle` proceeds: `raw_bal = 1 × P_t / 1e18 = 0` → `new_balance = 0`. Snapshots ARE updated here to `(P_t, I_t, C_t)`.
4. Attacker is now a zombie (initial=0). Further liquidations + fees grow `reward_index_one` to `I_now >> I_t`. `sp_settle` is never invoked on the zombie during this interval (no activity for them).
5. Attacker calls `sp_deposit(amt=1e11)`. `sp_settle` runs first; old behavior early-returned WITHOUT updating snapshots. Snapshots stay at `(P_t, I_t, C_t)` from step 3. Then `p.initial_balance = 0 + 1e11 = 1e11`.
6. Next `sp_claim`: `pending_one = (I_now − I_t) × 1e11 / P_t`. With `I_now − I_t = 5e19` and `P_t = 5e17`, pending_one ≈ 1e13 raw units ≈ 100,000 ONE from a 1,000 ONE deposit. Drained from `fee_pool`.

With R2-C01: step 5's `sp_settle` hits the early-return branch with initial=0, refreshes snapshots to `(P_now, I_now, C_now)` before returning. The redeposit then pairs the fresh `initial=1e11` with current-epoch snapshots. Next `sp_claim`: `pending_one = (I_future − I_now) × 1e11 / P_now` — only the honest delta since redeposit accrues. No phantom.

Regression test `test_zombie_redeposit_no_phantom_reward` locks this by asserting the snapshot values after a zombie settle match `PRECISION` and the current reward indices (not the seeded stale values).

### R2-M01 validation trace

On v0.1.1:
1. Victim opens trove `(coll=C, debt=D)`. Price drops; MCR fails but not liq-threshold (or victim doesn't immediately liquidate).
2. Attacker calls `redeem_impl` with `one_amt` tuned so `coll_out == t.collateral` exactly (guard at line 336 is `>=`, not `>`).
3. Post-update state: `(coll=0, debt=t.debt−net)`. Line 339 allows this as long as `t.debt == 0 || t.debt >= MIN_DEBT`.
4. Victim cannot `close_trove` — `close_impl` calls `fungible_asset::withdraw(treasury, 0)` which aborts (framework: amount must be > 0).
5. Liquidator cannot `liquidate` — same zero-withdraw abort on `total_seize_coll = 0`.
6. Debt sits in `total_debt` indefinitely.

With R2-M01: line 340 rejects the bad state at redeem time. Redeem either fully closes the trove (`t.debt = 0`) or must leave `t.collateral > 0`. No permanent bricked troves.

### False positives / deferrals from R2 (for reviewer awareness)

- **L-02 (`trove_health` u64 cast overflow)** — acknowledged tail-edge, real troves cannot reach the regime. View abort is visible to caller, no state corruption. Not fixed.
- **L-03 (view semantic ambiguity)** — 0-return for both "no trove" and "zero-debt trove" documented via existing `trove_of` / `is_sealed` call pattern. Not worth immutable-code real estate.
- **INFO-01 (u128 reward_index overflow over centuries)** — aligns with existing WARNING limitation (2). Not actionable.

---

## §2. Remaining open design questions

Both were surfaced in R1 and did not reach consensus. Claude R2 offered recommendations (below). Looking for a second independent opinion to cross-check.

### Q1 — Liquidation priority at extreme CR

Current code (§3 `liquidate`): liquidator bonus first (capped at seized collateral), reserve second (capped at remainder), SP gets residual collateral + absorbs debt burn.

At CR ≈ 150% (normal liquidation): nominal 25/25/50 split of the 10% bonus holds, SP loses on principal-vs-debt parity only.
At CR ≈ 110%: shortfall; SP receives less than its nominal share but still positive.
At CR ≈ 5%: liquidator takes entire remaining collateral (capped at seized), reserve and SP get zero collateral, SP still burns `debt` ONE.

**4/7 R1 auditors flagged this** (Kimi HIGH-2, Qwen F-1, Grok CRIT #1, ChatGPT #2). Alternatives offered:
- **A (current)**: liquidator priority. Ensures liquidation always has economic caller.
- **B**: SP priority. SP gets debt-worth first, remainder splits between liquidator/reserve.
- **C**: proportional. All three shares scale down together when collateral insufficient.
- **D**: hard CR floor. Abort liquidation below some threshold (e.g. 105%); bad debt accumulates without SP absorption.

**Claude R2 recommendation**: keep A, because:
- Tail events where CR < 100% typically mean the oracle is stale or crashed; no liquidator races for those anyway.
- Option B removes liquidator incentive; Option C adds code complexity without changing aggregate SP loss; Option D creates persistent bad debt in an immutable protocol (can't add cleanup later).
- Real defense against asymmetric SP loss is via Q2 (MIN_DEBT raise), not split policy.

**Your input wanted**: concur with keeping A, or argue for B/C/D with specific reasoning.

### Q2 — MIN_DEBT raise

Current: `MIN_DEBT = 100_000_000` = 1 ONE = $1.

Raised concerns: at $1 minimum, liquidator bonus at nominal 2.5% of debt = $0.025, below Aptos gas cost. Dust troves become permanent bad debt. An attacker sprays dust troves cheaply; none get liquidated economically, all accumulate as bad debt.

Historical norms: Liquity original used $2000. Mainnet-era DeFi range: $50–$2000.

Options:
- **$1 (current)**: retail-friendly but economically weak.
- **$100 (100 ONE)**: liquidator nets ~$2.50. Attack capital scales 100×. Claude R2 recommended.
- **$1000**: matches Liquity original. Excludes small users from an immutable protocol.
- **$10**: compromise. Liquidator nets $0.25; borderline economic. Not preferred.

**Claude R2 recommendation**: raise to 100 ONE ($100).

**Your input wanted**: concur, or pick different value, or argue for keeping $1.

---

## §3. Full source

### Move.toml

```toml
[package]
name = "ONE"
version = "0.1.2"
upgrade_policy = "compatible"
# Immutability achieved via resource-account deploy + destroyed SignerCapability
# (separate destroy_cap tx after publish). Package upgrade_policy stays "compatible"
# because deps are compatible.

[addresses]
ONE = "_"
origin = "0x0047a3e13465172e10661e20b7b618235e9c7e62a365d315e91cf1ef647321c9"
pyth = "0x7e783b349d3e89cf5931af376ebeadbfab855b3fa239b7ada8f5a92fbea6b387"

[dependencies]
AptosFramework = { git = "https://github.com/aptos-labs/aptos-core.git", subdir = "aptos-move/framework/aptos-framework", rev = "mainnet" }
Pyth = { local = "deps/pyth" }
```

### deps/pyth/sources/ (interface stub — bodies abort, real Pyth called at runtime)

```move
module pyth::pyth {
    use aptos_framework::coin::Coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use pyth::price_identifier::PriceIdentifier;
    use pyth::price::Price;
    public fun get_price(_p: &PriceIdentifier): Price { abort 0 }
    public fun get_price_no_older_than(_p: PriceIdentifier, _max_age_secs: u64): Price { abort 0 }
    public fun get_price_unsafe(_p: &PriceIdentifier): Price { abort 0 }
    public fun get_update_fee(_v: &vector<vector<u8>>): u64 { abort 0 }
    public fun update_price_feeds(_v: vector<vector<u8>>, _fee: Coin<AptosCoin>) { abort 0 }
    public entry fun update_price_feeds_with_funder(_signer: &signer, _vaas: vector<vector<u8>>) { abort 0 }
}

module pyth::price {
    use pyth::i64::I64;
    struct Price has copy, drop, store { price: I64, conf: u64, expo: I64, timestamp: u64 }
    public fun get_price(_p: &Price): I64 { abort 0 }
    public fun get_conf(_p: &Price): u64 { abort 0 }
    public fun get_expo(_p: &Price): I64 { abort 0 }
    public fun get_timestamp(_p: &Price): u64 { abort 0 }
}

module pyth::i64 {
    struct I64 has copy, drop, store { negative: bool, magnitude: u64 }
    public fun get_is_negative(_i: &I64): bool { abort 0 }
    public fun get_magnitude_if_positive(_i: &I64): u64 { abort 0 }
    public fun get_magnitude_if_negative(_i: &I64): u64 { abort 0 }
}

module pyth::price_identifier {
    struct PriceIdentifier has copy, drop, store { bytes: vector<u8> }
    public fun from_byte_vec(_b: vector<u8>): PriceIdentifier { abort 0 }
}
```

### sources/ONE.move

```move
/// ONE — immutable stablecoin on Aptos
///
/// WARNING: ONE is an immutable stablecoin contract that depends on
/// Pyth Network's on-chain price feed for APT/USD. If Pyth degrades or
/// misrepresents its oracle, ONE's peg mechanism breaks deterministically
/// - users can wind down via self-close without any external assistance,
/// but new mint/redeem operations become unreliable or frozen.
/// one is immutable = bug is real. Audit this code yourself before
/// interacting.
module ONE::ONE {
    use std::option::{Self, Option};
    use std::signer;
    use std::string;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_framework::account::SignerCapability;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, MintRef, BurnRef, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::resource_account;
    use aptos_framework::timestamp;
    use pyth::pyth;
    use pyth::price::{Self, Price};
    use pyth::i64;
    use pyth::price_identifier;

    const MCR_BPS: u128 = 20000;
    const LIQ_THRESHOLD_BPS: u128 = 15000;
    const LIQ_BONUS_BPS: u64 = 1000;
    const LIQ_LIQUIDATOR_BPS: u64 = 2500;
    const LIQ_SP_RESERVE_BPS: u64 = 2500;
    // SP receives (10000 - LIQ_LIQUIDATOR_BPS - LIQ_SP_RESERVE_BPS) = 5000 (50%) as remainder
    const FEE_BPS: u64 = 100;
    const STALENESS_SECS: u64 = 60;
    const MIN_DEBT: u64 = 100_000_000;
    const PRECISION: u128 = 1_000_000_000_000_000_000;
    const MIN_P_THRESHOLD: u128 = 1_000_000_000;
    const APT_FA: address = @0xa;
    const APT_USD_PYTH_FEED: vector<u8> = x"03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5";
    const MAX_CONF_BPS: u64 = 200;                    // Pyth confidence cap: 2% of price

    const E_COLLATERAL: u64 = 1;
    const E_TROVE: u64 = 2;
    const E_DEBT_MIN: u64 = 3;
    const E_STALE: u64 = 4;
    const E_SP_BAL: u64 = 5;
    const E_AMOUNT: u64 = 6;
    const E_TARGET: u64 = 7;
    const E_HEALTHY: u64 = 8;
    const E_SP_INSUFFICIENT: u64 = 9;
    const E_INSUFFICIENT_RESERVE: u64 = 10;
    const E_PRICE_ZERO: u64 = 11;
    const E_EXPO_BOUND: u64 = 12;
    const E_DECIMAL_OVERFLOW: u64 = 13;
    const E_P_CLIFF: u64 = 14;
    const E_PRICE_EXPO: u64 = 15;
    const E_PRICE_NEG: u64 = 16;
    const E_NOT_ORIGIN: u64 = 17;
    const E_CAP_GONE: u64 = 18;
    const E_PRICE_UNCERTAIN: u64 = 19;

    const WARNING: vector<u8> = b"ONE is an immutable stablecoin contract on Aptos that depends on Pyth Network's on-chain price feed for APT/USD. If Pyth degrades or misrepresents its oracle, ONE's peg mechanism breaks deterministically - users can wind down via self-close without any external assistance, but new mint/redeem operations become unreliable or frozen. one is immutable = bug is real. Audit this code yourself before interacting. KNOWN LIMITATIONS: (1) Stability Pool enters frozen state when product_factor would drop below 1e9 - protocol aborts further liquidations rather than corrupt SP accounting, accepting bad-debt accumulation past the threshold. (2) Sustained large-scale activity over decades may asymptotically exceed u64 bounds on pending SP rewards. (3) Liquidation seized collateral is distributed in priority: liquidator bonus first (nominal 2.5 percent of debt value, being 25 percent of the 10 percent liquidation bonus), then 2.5 percent reserve share (also 25 percent of bonus), then SP absorbs the remainder and the debt burn. At CR roughly 110% to 150% the SP alone covers the collateral shortfall. At CR below ~5% the liquidator may take the entire remaining collateral, reserve and SP receive zero, and SP still absorbs the full debt burn. (4) 25 percent of each fee is burned, creating a structural 0.25 percent aggregate supply-vs-debt gap per cycle (which rises to 1 percent during SP-empty windows because the remaining 75 percent also burns); individual debtors also face a 1 percent per-trove shortfall because only 99 percent is minted while 100 percent is needed to close - full protocol wind-down requires secondary-market ONE for the last debt closure. (5) Self-redemption (redeem against own trove) is allowed and behaves as partial debt repayment plus collateral withdrawal with a 1 percent fee. (6) Pyth is pull-based on Aptos - callers must ensure price is fresh (within 60 seconds) via pyth::update_price_feeds VAA update before invoking any ONE entry that reads the oracle. (7) Extreme low-price regimes may cause transient aborts in redeem paths when requested amounts exceed u64 output bounds; use smaller amounts and retry. (8) PERMANENT ORACLE FREEZE: if the Pyth package at 0x7e78... is upgraded in a breaking way, the APT/USD feed id 0x03ae4d... is de-registered, or the feed ever becomes permanently unavailable for any reason, the oracle-dependent entries (open_trove, redeem, liquidate, redeem_from_reserve, and their *_pyth wrappers) abort permanently. Oracle-free escape hatches remain fully open: close_trove lets any trove owner reclaim their collateral by burning the full trove debt in ONE (acquiring the 1 percent close deficit via secondary market if needed); add_collateral lets owners top up existing troves without touching the oracle; sp_deposit, sp_withdraw, and sp_claim let SP depositors manage and exit their positions and claim any rewards accumulated before the freeze. Protocol-owned APT held in reserve_coll becomes permanently locked because redeem_from_reserve requires the oracle. No admin override exists; the freeze is final.";

    struct Trove has store, drop { collateral: u64, debt: u64 }

    struct SP has store, drop {
        initial_balance: u64,
        snapshot_product: u128,
        snapshot_index_one: u128,
        snapshot_index_coll: u128,
    }

    /// Staged between publish and destroy_cap. Origin consumes + drops the cap to seal the package.
    struct ResourceCap has key { cap: Option<SignerCapability> }

    struct Registry has key {
        metadata: Object<Metadata>,
        apt_metadata: Object<Metadata>,
        mint_ref: MintRef,
        burn_ref: BurnRef,
        fee_pool: Object<FungibleStore>,
        fee_extend: ExtendRef,
        sp_pool: Object<FungibleStore>,
        sp_extend: ExtendRef,
        sp_coll_pool: Object<FungibleStore>,
        sp_coll_extend: ExtendRef,
        reserve_coll: Object<FungibleStore>,
        reserve_extend: ExtendRef,
        treasury: Object<FungibleStore>,
        treasury_extend: ExtendRef,
        troves: SmartTable<address, Trove>,
        sp_positions: SmartTable<address, SP>,
        total_debt: u64,
        total_sp: u64,
        product_factor: u128,
        reward_index_one: u128,
        reward_index_coll: u128,
    }

    #[event] struct TroveOpened has drop, store { user: address, new_collateral: u64, new_debt: u64, added_debt: u64 }
    #[event] struct CollateralAdded has drop, store { user: address, amount: u64 }
    #[event] struct TroveClosed has drop, store { user: address, collateral: u64, debt: u64 }
    #[event] struct Redeemed has drop, store { user: address, target: address, one_amt: u64, coll_out: u64 }
    #[event] struct Liquidated has drop, store { liquidator: address, target: address, debt: u64, coll_to_liquidator: u64, coll_to_sp: u64, coll_to_reserve: u64, coll_to_target: u64 }
    #[event] struct SPDeposited has drop, store { user: address, amount: u64 }
    #[event] struct SPWithdrew has drop, store { user: address, amount: u64 }
    #[event] struct SPClaimed has drop, store { user: address, one_amt: u64, coll_amt: u64 }
    #[event] struct ReserveRedeemed has drop, store { user: address, one_amt: u64, coll_out: u64 }
    #[event] struct FeeBurned has drop, store { amount: u64 }
    #[event] struct CapDestroyed has drop, store { caller: address, timestamp: u64 }
    #[event] struct RewardSaturated has drop, store { user: address, pending_one_truncated: bool, pending_coll_truncated: bool }

    fun init_module(resource: &signer) {
        let cap = resource_account::retrieve_resource_account_cap(resource, @origin);
        move_to(resource, ResourceCap { cap: option::some(cap) });
        init_module_inner(resource, object::address_to_object<Metadata>(APT_FA));
    }

    /// Origin-only. One-shot consume of the staged SignerCapability. After success,
    /// no actor can reconstruct a signer for @ONE — package is permanently sealed.
    public entry fun destroy_cap(caller: &signer) acquires ResourceCap {
        assert!(signer::address_of(caller) == @origin, E_NOT_ORIGIN);
        assert!(exists<ResourceCap>(@ONE), E_CAP_GONE);
        let ResourceCap { cap } = move_from<ResourceCap>(@ONE);
        let _sc = option::destroy_some(cap);
        event::emit(CapDestroyed { caller: signer::address_of(caller), timestamp: timestamp::now_seconds() });
    }

    fun init_module_inner(deployer: &signer, apt_md: Object<Metadata>) {
        let ctor = object::create_named_object(deployer, b"ONE");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &ctor, option::none(),
            string::utf8(b"ONE"), string::utf8(b"1"), 8,
            string::utf8(b""), string::utf8(b""),
        );
        let metadata = object::object_from_constructor_ref<Metadata>(&ctor);
        let da = signer::address_of(deployer);
        let fee_ctor = object::create_object(da);
        let sp_ctor = object::create_object(da);
        let sp_coll_ctor = object::create_object(da);
        let reserve_ctor = object::create_object(da);
        let tr_ctor = object::create_object(da);
        move_to(deployer, Registry {
            metadata,
            apt_metadata: apt_md,
            mint_ref: fungible_asset::generate_mint_ref(&ctor),
            burn_ref: fungible_asset::generate_burn_ref(&ctor),
            fee_pool: fungible_asset::create_store(&fee_ctor, metadata),
            fee_extend: object::generate_extend_ref(&fee_ctor),
            sp_pool: fungible_asset::create_store(&sp_ctor, metadata),
            sp_extend: object::generate_extend_ref(&sp_ctor),
            sp_coll_pool: fungible_asset::create_store(&sp_coll_ctor, apt_md),
            sp_coll_extend: object::generate_extend_ref(&sp_coll_ctor),
            reserve_coll: fungible_asset::create_store(&reserve_ctor, apt_md),
            reserve_extend: object::generate_extend_ref(&reserve_ctor),
            treasury: fungible_asset::create_store(&tr_ctor, apt_md),
            treasury_extend: object::generate_extend_ref(&tr_ctor),
            troves: smart_table::new(),
            sp_positions: smart_table::new(),
            total_debt: 0,
            total_sp: 0,
            product_factor: PRECISION,
            reward_index_one: 0,
            reward_index_coll: 0,
        });
    }

    fun price_8dec(): u128 {
        let id = price_identifier::from_byte_vec(APT_USD_PYTH_FEED);
        let p: Price = pyth::get_price_no_older_than(id, STALENESS_SECS);
        let p_i64 = price::get_price(&p);
        let e_i64 = price::get_expo(&p);
        let ts = price::get_timestamp(&p);
        let conf = price::get_conf(&p);
        let now = timestamp::now_seconds();
        assert!(ts + STALENESS_SECS >= now, E_STALE);
        assert!(ts <= now + 10, E_STALE);
        assert!(i64::get_is_negative(&e_i64), E_PRICE_EXPO);
        let abs_e = i64::get_magnitude_if_negative(&e_i64);
        assert!(abs_e <= 18, E_EXPO_BOUND);
        assert!(!i64::get_is_negative(&p_i64), E_PRICE_NEG);
        let raw = (i64::get_magnitude_if_positive(&p_i64) as u128);
        assert!(raw > 0, E_PRICE_ZERO);
        // Reject prices with wide confidence interval — Pyth signals uncertainty via conf.
        // Cap conf/raw ratio at MAX_CONF_BPS (2% default) in raw units (conf shares price's expo).
        assert!((conf as u128) * 10000 <= (MAX_CONF_BPS as u128) * raw, E_PRICE_UNCERTAIN);
        let result = if (abs_e >= 8) {
            raw / pow10(abs_e - 8)
        } else {
            raw * pow10(8 - abs_e)
        };
        assert!(result > 0, E_PRICE_ZERO);
        result
    }

    fun pow10(n: u64): u128 {
        assert!(n <= 38, E_DECIMAL_OVERFLOW);
        let r: u128 = 1;
        while (n > 0) { r = r * 10; n = n - 1; };
        r
    }

    fun route_fee_fa(r: &mut Registry, fa: FungibleAsset) {
        let amt = fungible_asset::amount(&fa);
        if (amt == 0) { fungible_asset::destroy_zero(fa); return };
        let burn_amt = (((amt as u128) * 2500) / 10000) as u64;
        if (burn_amt > 0) {
            let burn_portion = fungible_asset::extract(&mut fa, burn_amt);
            fungible_asset::burn(&r.burn_ref, burn_portion);
            event::emit(FeeBurned { amount: burn_amt });
        };
        let sp_amt = fungible_asset::amount(&fa);
        if (sp_amt == 0) { fungible_asset::destroy_zero(fa); return };
        if (r.total_sp == 0) {
            fungible_asset::burn(&r.burn_ref, fa);
        } else {
            fungible_asset::deposit(r.fee_pool, fa);
            r.reward_index_one = r.reward_index_one + (sp_amt as u128) * r.product_factor / (r.total_sp as u128);
        }
    }

    fun sp_settle(r: &mut Registry, u: address) {
        let pos = smart_table::borrow_mut(&mut r.sp_positions, u);
        let snap_p = pos.snapshot_product;
        let snap_i_one = pos.snapshot_index_one;
        let snap_i_coll = pos.snapshot_index_coll;
        let initial = pos.initial_balance;
        if (snap_p == 0 || initial == 0) {
            pos.snapshot_product = r.product_factor;
            pos.snapshot_index_one = r.reward_index_one;
            pos.snapshot_index_coll = r.reward_index_coll;
            return;
        };

        let u64_max: u256 = 18446744073709551615;
        let raw_one = ((r.reward_index_one - snap_i_one) as u256) * (initial as u256) / (snap_p as u256);
        let raw_coll = ((r.reward_index_coll - snap_i_coll) as u256) * (initial as u256) / (snap_p as u256);
        let raw_bal = (initial as u256) * (r.product_factor as u256) / (snap_p as u256);
        // Saturate at u64::MAX rather than abort — prevents permanent SP position lock
        // if decades of fee accrual push pending rewards past u64 bounds. User loses only
        // the astronomical excess above 1.8e19 raw units.
        let one_trunc = raw_one > u64_max;
        let coll_trunc = raw_coll > u64_max;
        let pending_one = (if (one_trunc) u64_max else raw_one) as u64;
        let pending_coll = (if (coll_trunc) u64_max else raw_coll) as u64;
        let new_balance = (if (raw_bal > u64_max) u64_max else raw_bal) as u64;
        if (one_trunc || coll_trunc) {
            event::emit(RewardSaturated { user: u, pending_one_truncated: one_trunc, pending_coll_truncated: coll_trunc });
        };

        pos.initial_balance = new_balance;
        pos.snapshot_product = r.product_factor;
        pos.snapshot_index_one = r.reward_index_one;
        pos.snapshot_index_coll = r.reward_index_coll;

        if (pending_one > 0) {
            let fee_signer = object::generate_signer_for_extending(&r.fee_extend);
            let fa = fungible_asset::withdraw(&fee_signer, r.fee_pool, pending_one);
            primary_fungible_store::deposit(u, fa);
        };
        if (pending_coll > 0) {
            let coll_signer = object::generate_signer_for_extending(&r.sp_coll_extend);
            let fa = fungible_asset::withdraw(&coll_signer, r.sp_coll_pool, pending_coll);
            primary_fungible_store::deposit(u, fa);
        };
        if (pending_one > 0 || pending_coll > 0) {
            event::emit(SPClaimed { user: u, one_amt: pending_one, coll_amt: pending_coll });
        }
    }

    fun open_impl(user_addr: address, fa_coll: FungibleAsset, debt: u64) acquires Registry {
        assert!(debt >= MIN_DEBT, E_DEBT_MIN);
        let coll_amt = fungible_asset::amount(&fa_coll);
        let r = borrow_global_mut<Registry>(@ONE);
        let price = price_8dec();

        let is_existing = smart_table::contains(&r.troves, user_addr);
        let (prior_coll, prior_debt) = if (is_existing) {
            let t = smart_table::borrow(&r.troves, user_addr);
            (t.collateral, t.debt)
        } else (0, 0);
        let new_coll = prior_coll + coll_amt;
        let new_debt = prior_debt + debt;
        let coll_usd = (new_coll as u128) * price / 100_000_000;
        assert!(coll_usd * 10000 >= MCR_BPS * (new_debt as u128), E_COLLATERAL);

        fungible_asset::deposit(r.treasury, fa_coll);
        let fee = (((debt as u128) * (FEE_BPS as u128)) / 10000) as u64;
        let user_fa = fungible_asset::mint(&r.mint_ref, debt - fee);
        let fee_fa = fungible_asset::mint(&r.mint_ref, fee);
        primary_fungible_store::deposit(user_addr, user_fa);
        route_fee_fa(r, fee_fa);

        if (is_existing) {
            let t = smart_table::borrow_mut(&mut r.troves, user_addr);
            t.collateral = new_coll;
            t.debt = new_debt;
        } else {
            smart_table::add(&mut r.troves, user_addr, Trove { collateral: new_coll, debt: new_debt });
        };
        r.total_debt = r.total_debt + debt;
        event::emit(TroveOpened { user: user_addr, new_collateral: new_coll, new_debt, added_debt: debt });
    }

    fun add_impl(user_addr: address, fa_coll: FungibleAsset) acquires Registry {
        let amt = fungible_asset::amount(&fa_coll);
        assert!(amt > 0, E_AMOUNT);
        let r = borrow_global_mut<Registry>(@ONE);
        assert!(smart_table::contains(&r.troves, user_addr), E_TROVE);
        fungible_asset::deposit(r.treasury, fa_coll);
        let t = smart_table::borrow_mut(&mut r.troves, user_addr);
        t.collateral = t.collateral + amt;
        event::emit(CollateralAdded { user: user_addr, amount: amt });
    }

    fun close_impl(user: &signer): FungibleAsset acquires Registry {
        let u = signer::address_of(user);
        let r = borrow_global_mut<Registry>(@ONE);
        assert!(smart_table::contains(&r.troves, u), E_TROVE);
        let t = smart_table::remove(&mut r.troves, u);
        if (t.debt > 0) {
            fungible_asset::burn(&r.burn_ref, primary_fungible_store::withdraw(user, r.metadata, t.debt));
        };
        r.total_debt = r.total_debt - t.debt;
        event::emit(TroveClosed { user: u, collateral: t.collateral, debt: t.debt });
        let sr = object::generate_signer_for_extending(&r.treasury_extend);
        fungible_asset::withdraw(&sr, r.treasury, t.collateral)
    }

    fun redeem_impl(user: &signer, one_amt: u64, target: address): FungibleAsset acquires Registry {
        assert!(one_amt >= MIN_DEBT, E_AMOUNT);
        let r = borrow_global_mut<Registry>(@ONE);
        assert!(smart_table::contains(&r.troves, target), E_TARGET);
        let price = price_8dec();
        let fee = (((one_amt as u128) * (FEE_BPS as u128)) / 10000) as u64;
        let net = one_amt - fee;
        let coll_out = (((net as u128) * 100_000_000 / price) as u64);

        let t = smart_table::borrow_mut(&mut r.troves, target);
        assert!(t.debt >= net, E_TARGET);
        assert!(t.collateral >= coll_out, E_COLLATERAL);
        t.debt = t.debt - net;
        t.collateral = t.collateral - coll_out;
        assert!(t.debt == 0 || t.debt >= MIN_DEBT, E_DEBT_MIN);
        assert!(t.debt == 0 || t.collateral > 0, E_COLLATERAL);

        let user_fa = primary_fungible_store::withdraw(user, r.metadata, one_amt);
        let fee_fa = fungible_asset::extract(&mut user_fa, fee);
        fungible_asset::burn(&r.burn_ref, user_fa);
        route_fee_fa(r, fee_fa);
        r.total_debt = r.total_debt - net;
        let u = signer::address_of(user);
        event::emit(Redeemed { user: u, target, one_amt, coll_out });
        let sr = object::generate_signer_for_extending(&r.treasury_extend);
        fungible_asset::withdraw(&sr, r.treasury, coll_out)
    }

    public entry fun open_trove(user: &signer, coll_amt: u64, debt: u64) acquires Registry {
        let apt_md = borrow_global<Registry>(@ONE).apt_metadata;
        let fa = primary_fungible_store::withdraw(user, apt_md, coll_amt);
        open_impl(signer::address_of(user), fa, debt);
    }

    public entry fun add_collateral(user: &signer, coll_amt: u64) acquires Registry {
        let apt_md = borrow_global<Registry>(@ONE).apt_metadata;
        let fa = primary_fungible_store::withdraw(user, apt_md, coll_amt);
        add_impl(signer::address_of(user), fa);
    }

    public entry fun close_trove(user: &signer) acquires Registry {
        primary_fungible_store::deposit(signer::address_of(user), close_impl(user));
    }

    public entry fun redeem(user: &signer, one_amt: u64, target: address) acquires Registry {
        primary_fungible_store::deposit(
            signer::address_of(user), redeem_impl(user, one_amt, target)
        );
    }

    public entry fun redeem_from_reserve(user: &signer, one_amt: u64) acquires Registry {
        assert!(one_amt >= MIN_DEBT, E_AMOUNT);
        let r = borrow_global_mut<Registry>(@ONE);
        let price = price_8dec();
        let fee = (((one_amt as u128) * (FEE_BPS as u128)) / 10000) as u64;
        let net = one_amt - fee;
        let coll_out = (((net as u128) * 100_000_000 / price) as u64);
        assert!(fungible_asset::balance(r.reserve_coll) >= coll_out, E_INSUFFICIENT_RESERVE);

        // Reserve redemption burns ONE against protocol-owned collateral. No trove is
        // being closed here, so total_debt (= sum of per-trove debts) is intentionally
        // not decremented. Circulating supply falls while total_debt stays — this widens
        // the supply-vs-debt gap, which is the intended reserve-drain mechanic.
        let user_fa = primary_fungible_store::withdraw(user, r.metadata, one_amt);
        let fee_fa = fungible_asset::extract(&mut user_fa, fee);
        fungible_asset::burn(&r.burn_ref, user_fa);
        route_fee_fa(r, fee_fa);

        let sr = object::generate_signer_for_extending(&r.reserve_extend);
        let out = fungible_asset::withdraw(&sr, r.reserve_coll, coll_out);
        primary_fungible_store::deposit(signer::address_of(user), out);

        event::emit(ReserveRedeemed { user: signer::address_of(user), one_amt, coll_out });
    }

    public entry fun liquidate(liquidator: &signer, target: address) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        assert!(smart_table::contains(&r.troves, target), E_TARGET);
        let price = price_8dec();
        let t_ref = smart_table::borrow(&r.troves, target);
        let debt = t_ref.debt;
        let coll = t_ref.collateral;
        let coll_usd = (coll as u128) * price / 100_000_000;

        assert!(coll_usd * 10000 < LIQ_THRESHOLD_BPS * (debt as u128), E_HEALTHY);
        assert!(r.total_sp > debt, E_SP_INSUFFICIENT);

        let total_before = r.total_sp;
        let new_p = r.product_factor * ((total_before - debt) as u128) / (total_before as u128);
        assert!(new_p >= MIN_P_THRESHOLD, E_P_CLIFF);

        let bonus_usd = (debt as u128) * (LIQ_BONUS_BPS as u128) / 10000;
        let liq_share_usd = bonus_usd * (LIQ_LIQUIDATOR_BPS as u128) / 10000;
        let reserve_share_usd = bonus_usd * (LIQ_SP_RESERVE_BPS as u128) / 10000;
        let total_seize_usd = (debt as u128) + bonus_usd;
        let total_seize_u128 = total_seize_usd * 100_000_000 / price;
        let coll_u128 = (coll as u128);
        let total_seize_coll = (if (total_seize_u128 > coll_u128) coll_u128 else total_seize_u128) as u64;
        let liq_u128 = liq_share_usd * 100_000_000 / price;
        let total_seize_coll_u128 = (total_seize_coll as u128);
        let liq_coll = (if (liq_u128 > total_seize_coll_u128) total_seize_coll_u128 else liq_u128) as u64;
        let remaining_u128 = total_seize_coll_u128 - (liq_coll as u128);
        let reserve_u128 = reserve_share_usd * 100_000_000 / price;
        let reserve_coll_amt = (if (reserve_u128 > remaining_u128) remaining_u128 else reserve_u128) as u64;
        let sp_coll = total_seize_coll - liq_coll - reserve_coll_amt;
        let target_remainder = coll - total_seize_coll;

        smart_table::remove(&mut r.troves, target);
        r.total_debt = r.total_debt - debt;

        let sp_signer = object::generate_signer_for_extending(&r.sp_extend);
        let burn_fa = fungible_asset::withdraw(&sp_signer, r.sp_pool, debt);
        fungible_asset::burn(&r.burn_ref, burn_fa);

        r.reward_index_coll = r.reward_index_coll +
            (sp_coll as u128) * r.product_factor / (total_before as u128);
        r.product_factor = new_p;
        r.total_sp = total_before - debt;

        let tr_signer = object::generate_signer_for_extending(&r.treasury_extend);
        let seized = fungible_asset::withdraw(&tr_signer, r.treasury, total_seize_coll);
        let liq_fa = fungible_asset::extract(&mut seized, liq_coll);
        primary_fungible_store::deposit(signer::address_of(liquidator), liq_fa);
        let reserve_fa = fungible_asset::extract(&mut seized, reserve_coll_amt);
        fungible_asset::deposit(r.reserve_coll, reserve_fa);
        fungible_asset::deposit(r.sp_coll_pool, seized);

        if (target_remainder > 0) {
            let rem_fa = fungible_asset::withdraw(&tr_signer, r.treasury, target_remainder);
            primary_fungible_store::deposit(target, rem_fa);
        };

        event::emit(Liquidated {
            liquidator: signer::address_of(liquidator),
            target, debt,
            coll_to_liquidator: liq_coll,
            coll_to_sp: sp_coll,
            coll_to_reserve: reserve_coll_amt,
            coll_to_target: target_remainder,
        });
    }

    public entry fun sp_deposit(user: &signer, amt: u64) acquires Registry {
        assert!(amt > 0, E_AMOUNT);
        let u = signer::address_of(user);
        let r = borrow_global_mut<Registry>(@ONE);
        let fa_in = primary_fungible_store::withdraw(user, r.metadata, amt);
        fungible_asset::deposit(r.sp_pool, fa_in);
        // Reset-on-empty: when the pool has been fully drained (previous cliff-freeze
        // plus all prior depositors withdrew), reset product_factor to full precision
        // so liquidations can resume. No active depositor is harmed — there are none.
        if (r.total_sp == 0) {
            r.product_factor = PRECISION;
        };
        if (smart_table::contains(&r.sp_positions, u)) {
            sp_settle(r, u);
            let p = smart_table::borrow_mut(&mut r.sp_positions, u);
            p.initial_balance = p.initial_balance + amt;
        } else {
            smart_table::add(&mut r.sp_positions, u, SP {
                initial_balance: amt,
                snapshot_product: r.product_factor,
                snapshot_index_one: r.reward_index_one,
                snapshot_index_coll: r.reward_index_coll,
            });
        };
        r.total_sp = r.total_sp + amt;
        event::emit(SPDeposited { user: u, amount: amt });
    }

    public entry fun sp_withdraw(user: &signer, amt: u64) acquires Registry {
        assert!(amt > 0, E_AMOUNT);
        let u = signer::address_of(user);
        let r = borrow_global_mut<Registry>(@ONE);
        assert!(smart_table::contains(&r.sp_positions, u), E_SP_BAL);
        sp_settle(r, u);
        let pos = smart_table::borrow_mut(&mut r.sp_positions, u);
        assert!(pos.initial_balance >= amt, E_SP_BAL);
        pos.initial_balance = pos.initial_balance - amt;
        r.total_sp = r.total_sp - amt;
        let empty = pos.initial_balance == 0;
        let sr = object::generate_signer_for_extending(&r.sp_extend);
        primary_fungible_store::deposit(u, fungible_asset::withdraw(&sr, r.sp_pool, amt));
        if (empty) { smart_table::remove(&mut r.sp_positions, u); };
        event::emit(SPWithdrew { user: u, amount: amt });
    }

    public entry fun sp_claim(user: &signer) acquires Registry {
        let u = signer::address_of(user);
        let r = borrow_global_mut<Registry>(@ONE);
        assert!(smart_table::contains(&r.sp_positions, u), E_SP_BAL);
        sp_settle(r, u);
    }

    // Convenience wrappers that atomically refresh the Pyth feed before the oracle-dependent
    // entry. Integrators avoid the two-tx dance and cannot accidentally operate on a cached
    // price set by an unrelated actor. Raw entries above remain available.

    public entry fun open_trove_pyth(
        user: &signer, coll_amt: u64, debt: u64, vaas: vector<vector<u8>>
    ) acquires Registry {
        pyth::update_price_feeds_with_funder(user, vaas);
        let apt_md = borrow_global<Registry>(@ONE).apt_metadata;
        let fa = primary_fungible_store::withdraw(user, apt_md, coll_amt);
        open_impl(signer::address_of(user), fa, debt);
    }

    public entry fun redeem_pyth(
        user: &signer, one_amt: u64, target: address, vaas: vector<vector<u8>>
    ) acquires Registry {
        pyth::update_price_feeds_with_funder(user, vaas);
        primary_fungible_store::deposit(
            signer::address_of(user), redeem_impl(user, one_amt, target)
        );
    }

    public entry fun redeem_from_reserve_pyth(
        user: &signer, one_amt: u64, vaas: vector<vector<u8>>
    ) acquires Registry {
        pyth::update_price_feeds_with_funder(user, vaas);
        redeem_from_reserve(user, one_amt);
    }

    public entry fun liquidate_pyth(
        liquidator: &signer, target: address, vaas: vector<vector<u8>>
    ) acquires Registry {
        pyth::update_price_feeds_with_funder(liquidator, vaas);
        liquidate(liquidator, target);
    }

    #[view] public fun read_warning(): vector<u8> { WARNING }

    #[view] public fun metadata_addr(): address acquires Registry {
        object::object_address(&borrow_global<Registry>(@ONE).metadata)
    }

    #[view] public fun price(): u128 { price_8dec() }

    #[view] public fun trove_of(addr: address): (u64, u64) acquires Registry {
        let r = borrow_global<Registry>(@ONE);
        if (smart_table::contains(&r.troves, addr)) {
            let t = smart_table::borrow(&r.troves, addr);
            (t.collateral, t.debt)
        } else (0, 0)
    }

    #[view] public fun sp_of(addr: address): (u64, u64, u64) acquires Registry {
        let r = borrow_global<Registry>(@ONE);
        if (smart_table::contains(&r.sp_positions, addr)) {
            let p = smart_table::borrow(&r.sp_positions, addr);
            let eff = ((((p.initial_balance as u256) * (r.product_factor as u256)) / (p.snapshot_product as u256)) as u64);
            let p_one = ((((r.reward_index_one - p.snapshot_index_one) as u256) * (p.initial_balance as u256)) / (p.snapshot_product as u256)) as u64;
            let p_coll = ((((r.reward_index_coll - p.snapshot_index_coll) as u256) * (p.initial_balance as u256)) / (p.snapshot_product as u256)) as u64;
            (eff, p_one, p_coll)
        } else (0, 0, 0)
    }

    #[view] public fun totals(): (u64, u64, u128, u128, u128) acquires Registry {
        let r = borrow_global<Registry>(@ONE);
        (r.total_debt, r.total_sp, r.product_factor, r.reward_index_one, r.reward_index_coll)
    }

    #[view] public fun reserve_balance(): u64 acquires Registry {
        fungible_asset::balance(borrow_global<Registry>(@ONE).reserve_coll)
    }

    /// Returns true iff destroy_cap has been called (package permanently sealed).
    #[view] public fun is_sealed(): bool { !exists<ResourceCap>(@ONE) }

    /// Exact ONE amount user needs to burn in order to call close_trove on their own trove.
    /// Useful for front-ends to show the secondary-market ONE deficit pre-close.
    #[view] public fun close_cost(addr: address): u64 acquires Registry {
        let r = borrow_global<Registry>(@ONE);
        if (smart_table::contains(&r.troves, addr)) {
            smart_table::borrow(&r.troves, addr).debt
        } else 0
    }

    /// Returns (collateral, debt, cr_bps). cr_bps = 0 if no trove, or if oracle unavailable
    /// (caller must handle that case). Uses price_8dec() so shares its abort semantics on bad oracle.
    #[view] public fun trove_health(addr: address): (u64, u64, u64) acquires Registry {
        let r = borrow_global<Registry>(@ONE);
        if (!smart_table::contains(&r.troves, addr)) return (0, 0, 0);
        let t = smart_table::borrow(&r.troves, addr);
        if (t.debt == 0) return (t.collateral, 0, 0);
        let price = price_8dec();
        let coll_usd = (t.collateral as u128) * price / 100_000_000;
        let cr_bps = (coll_usd * 10000 / (t.debt as u128)) as u64;
        (t.collateral, t.debt, cr_bps)
    }

    #[test_only]
    public fun init_module_for_test(deployer: &signer, apt_md: Object<Metadata>) {
        init_module_inner(deployer, apt_md);
    }

    #[test_only]
    public fun test_stash_cap_for_test(deployer: &signer) {
        let fake = aptos_framework::account::create_test_signer_cap(signer::address_of(deployer));
        move_to(deployer, ResourceCap { cap: option::some(fake) });
    }

    #[test_only]
    public fun test_create_sp_position(addr: address, balance: u64) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        smart_table::add(&mut r.sp_positions, addr, SP {
            initial_balance: balance,
            snapshot_product: r.product_factor,
            snapshot_index_one: r.reward_index_one,
            snapshot_index_coll: r.reward_index_coll,
        });
        r.total_sp = r.total_sp + balance;
    }

    #[test_only]
    public fun test_route_fee_virtual(amount: u64) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        if (r.total_sp == 0) return;
        let sp_amt = amount - amount * 2500 / 10000;
        r.reward_index_one = r.reward_index_one + (sp_amt as u128) * r.product_factor / (r.total_sp as u128);
    }

    #[test_only]
    public fun test_create_trove(addr: address, collateral: u64, debt: u64) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        smart_table::add(&mut r.troves, addr, Trove { collateral, debt });
        r.total_debt = r.total_debt + debt;
    }

    #[test_only]
    public fun test_simulate_liquidation(debt: u64, sp_coll_absorbed: u64) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        let total_before = r.total_sp;
        assert!(total_before > debt, E_SP_INSUFFICIENT);
        let new_p = r.product_factor * ((total_before - debt) as u128) / (total_before as u128);
        assert!(new_p >= MIN_P_THRESHOLD, E_P_CLIFF);
        r.reward_index_coll = r.reward_index_coll +
            (sp_coll_absorbed as u128) * r.product_factor / (total_before as u128);
        r.product_factor = new_p;
        r.total_sp = total_before - debt;
    }

    #[test_only]
    public fun test_set_sp_position(
        addr: address, initial: u64, snap_p: u128, snap_i_one: u128, snap_i_coll: u128
    ) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        if (smart_table::contains(&r.sp_positions, addr)) {
            let p = smart_table::borrow_mut(&mut r.sp_positions, addr);
            p.initial_balance = initial;
            p.snapshot_product = snap_p;
            p.snapshot_index_one = snap_i_one;
            p.snapshot_index_coll = snap_i_coll;
        } else {
            smart_table::add(&mut r.sp_positions, addr, SP {
                initial_balance: initial,
                snapshot_product: snap_p,
                snapshot_index_one: snap_i_one,
                snapshot_index_coll: snap_i_coll,
            });
        };
    }

    #[test_only]
    public fun test_get_sp_snapshots(addr: address): (u64, u128, u128, u128) acquires Registry {
        let r = borrow_global<Registry>(@ONE);
        let p = smart_table::borrow(&r.sp_positions, addr);
        (p.initial_balance, p.snapshot_product, p.snapshot_index_one, p.snapshot_index_coll)
    }

    #[test_only]
    public fun test_force_reward_indices(one_idx: u128, coll_idx: u128) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        r.reward_index_one = one_idx;
        r.reward_index_coll = coll_idx;
    }

    #[test_only]
    public fun test_call_sp_settle(addr: address) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        sp_settle(r, addr);
    }
}
```

### tests/ONE_tests.move

```move
#[test_only]
module ONE::ONE_tests {
    use std::option;
    use std::string;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use ONE::ONE;

    const MOCK_APT_HOST: address = @0xABCD;

    fun setup(deployer: &signer): Object<Metadata> {
        timestamp::set_time_has_started_for_testing(
            &account::create_signer_for_test(@aptos_framework)
        );
        let apt_signer = account::create_signer_for_test(MOCK_APT_HOST);
        let ctor = object::create_named_object(&apt_signer, b"APT");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &ctor, option::none(),
            string::utf8(b"Aptos Coin"), string::utf8(b"APT"), 8,
            string::utf8(b""), string::utf8(b""),
        );
        let apt_md = object::object_from_constructor_ref<Metadata>(&ctor);
        ONE::init_module_for_test(deployer, apt_md);
        apt_md
    }

    #[test(deployer = @ONE)]
    fun test_init_creates_registry(deployer: &signer) {
        setup(deployer);
        let (debt, sp, p, r1, r2) = ONE::totals();
        assert!(debt == 0, 100);
        assert!(sp == 0, 101);
        assert!(p == 1_000_000_000_000_000_000, 102);
        assert!(r1 == 0, 103);
        assert!(r2 == 0, 104);
    }

    #[test(deployer = @ONE)]
    fun test_warning_text_on_chain(deployer: &signer) {
        setup(deployer);
        let w = ONE::read_warning();
        let prefix = b"ONE is an immutable stablecoin";
        let i = 0;
        while (i < vector::length(&prefix)) {
            assert!(*vector::borrow(&w, i) == *vector::borrow(&prefix, i), 200);
            i = i + 1;
        };
        let pyth_ref = b"Pyth Network";
        assert!(contains_bytes(&w, &pyth_ref), 201);
    }

    #[test(deployer = @ONE)]
    fun test_trove_of_unknown_returns_zero(deployer: &signer) {
        setup(deployer);
        let (c, d) = ONE::trove_of(@0xA11CE);
        assert!(c == 0 && d == 0, 300);
    }

    #[test(deployer = @ONE)]
    fun test_sp_of_unknown_returns_zero(deployer: &signer) {
        setup(deployer);
        let (bal, p_one, p_coll) = ONE::sp_of(@0xA11CE);
        assert!(bal == 0 && p_one == 0 && p_coll == 0, 400);
    }

    #[test(deployer = @ONE)]
    fun test_metadata_addr_stable(deployer: &signer) {
        setup(deployer);
        assert!(ONE::metadata_addr() == ONE::metadata_addr(), 500);
    }

    #[test(deployer = @ONE, user = @0xA11CE)]
    #[expected_failure(abort_code = 2, location = ONE::ONE)]
    fun test_close_trove_without_trove_aborts(deployer: &signer, user: &signer) {
        setup(deployer);
        ONE::close_trove(user);
    }

    #[test(deployer = @ONE, user = @0xA11CE)]
    #[expected_failure(abort_code = 5, location = ONE::ONE)]
    fun test_sp_claim_without_position_aborts(deployer: &signer, user: &signer) {
        setup(deployer);
        ONE::sp_claim(user);
    }

    #[test(deployer = @ONE, user = @0xA11CE)]
    #[expected_failure(abort_code = 5, location = ONE::ONE)]
    fun test_sp_withdraw_without_position_aborts(deployer: &signer, user: &signer) {
        setup(deployer);
        ONE::sp_withdraw(user, 100_000_000);
    }

    #[test(deployer = @ONE, user = @0xA11CE)]
    #[expected_failure(abort_code = 6, location = ONE::ONE)]
    fun test_sp_deposit_zero_aborts(deployer: &signer, user: &signer) {
        setup(deployer);
        ONE::sp_deposit(user, 0);
    }

    #[test(deployer = @ONE)]
    fun test_sp_position_creation_via_helper(deployer: &signer) {
        setup(deployer);
        let u = @0xBEEF;
        ONE::test_create_sp_position(u, 100_000_000);
        let (bal, p_one, p_coll) = ONE::sp_of(u);
        assert!(bal == 100_000_000, 600);
        assert!(p_one == 0, 601);
        assert!(p_coll == 0, 602);
    }

    #[test(deployer = @ONE)]
    fun test_reward_index_increment_and_pending(deployer: &signer) {
        setup(deployer);
        let u = @0xBEEF;
        ONE::test_create_sp_position(u, 100_000_000);
        ONE::test_route_fee_virtual(1_000_000);
        let (_, _, _, r_one, _) = ONE::totals();
        assert!(r_one == 7_500_000_000_000_000, 700);
        let (bal, p_one, p_coll) = ONE::sp_of(u);
        assert!(bal == 100_000_000, 701);
        assert!(p_one == 750_000, 702);
        assert!(p_coll == 0, 703);
    }

    #[test(deployer = @ONE)]
    fun test_reward_index_pro_rata_two_depositors(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 200_000_000);
        ONE::test_create_sp_position(@0xBBBB, 100_000_000);
        ONE::test_route_fee_virtual(300_000_000);
        let (_, pa, _) = ONE::sp_of(@0xAAAA);
        let (_, pb, _) = ONE::sp_of(@0xBBBB);
        assert!(pa == 150_000_000, 800);
        assert!(pb == 75_000_000, 801);
    }

    #[test(deployer = @ONE)]
    fun test_liquidation_single_depositor(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        ONE::test_simulate_liquidation(2_000_000_000, 2_500_000_000);
        let (bal, p_one, p_coll) = ONE::sp_of(@0xAAAA);
        assert!(bal == 8_000_000_000, 900);
        assert!(p_one == 0, 901);
        assert!(p_coll == 2_500_000_000, 902);
        let (_, total_sp, pf, _, r_coll) = ONE::totals();
        assert!(total_sp == 8_000_000_000, 903);
        assert!(pf == 800_000_000_000_000_000, 904);
        assert!(r_coll == 250_000_000_000_000_000, 905);
    }

    #[test(deployer = @ONE)]
    fun test_liquidation_two_depositors_pro_rata(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        ONE::test_create_sp_position(@0xBBBB, 10_000_000_000);
        ONE::test_simulate_liquidation(2_000_000_000, 2_500_000_000);
        let (a_bal, _, a_coll) = ONE::sp_of(@0xAAAA);
        let (b_bal, _, b_coll) = ONE::sp_of(@0xBBBB);
        assert!(a_bal == 9_000_000_000, 1000);
        assert!(b_bal == 9_000_000_000, 1001);
        assert!(a_coll == 1_250_000_000, 1002);
        assert!(b_coll == 1_250_000_000, 1003);
    }

    #[test(deployer = @ONE)]
    fun test_liquidation_sequential_math(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        ONE::test_simulate_liquidation(2_000_000_000, 2_500_000_000);
        ONE::test_create_sp_position(@0xBBBB, 10_000_000_000);
        ONE::test_simulate_liquidation(1_000_000_000, 1_500_000_000);
        let (a_bal, _, a_coll) = ONE::sp_of(@0xAAAA);
        assert!(a_bal == 7_555_555_555, 1100);
        assert!(a_coll == 3_166_666_666, 1101);
        let (b_bal, _, b_coll) = ONE::sp_of(@0xBBBB);
        assert!(b_bal == 9_444_444_444, 1102);
        assert!(b_coll == 833_333_333, 1103);
    }

    #[test(deployer = @ONE)]
    #[expected_failure(abort_code = 14, location = ONE::ONE)]
    fun test_liquidation_cliff_guard_aborts(deployer: &signer) {
        setup(deployer);
        ONE::test_create_sp_position(@0xAAAA, 10_000_000_000);
        ONE::test_simulate_liquidation(9_999_999_000, 1_000_000_000);
        ONE::test_simulate_liquidation(999, 500);
    }

    // --- destroy_cap / ResourceCap tests ---

    #[test(deployer = @ONE)]
    #[expected_failure(abort_code = 17, location = ONE::ONE)]
    fun test_destroy_cap_non_origin_aborts(deployer: &signer) {
        setup(deployer);
        ONE::test_stash_cap_for_test(deployer);
        let attacker = account::create_signer_for_test(@0xBEEF);
        ONE::destroy_cap(&attacker);
    }

    #[test(deployer = @ONE)]
    fun test_destroy_cap_consumes_resource(deployer: &signer) {
        setup(deployer);
        ONE::test_stash_cap_for_test(deployer);
        let origin = account::create_signer_for_test(@origin);
        ONE::destroy_cap(&origin);
    }

    #[test(deployer = @ONE)]
    #[expected_failure(abort_code = 18, location = ONE::ONE)]
    fun test_destroy_cap_double_call_aborts(deployer: &signer) {
        setup(deployer);
        ONE::test_stash_cap_for_test(deployer);
        let origin = account::create_signer_for_test(@origin);
        ONE::destroy_cap(&origin);
        ONE::destroy_cap(&origin);
    }

    fun contains_bytes(hay: &vector<u8>, needle: &vector<u8>): bool {
        let hn = vector::length(hay);
        let nn = vector::length(needle);
        if (nn == 0 || nn > hn) return nn == 0;
        let i = 0;
        while (i + nn <= hn) {
            let j = 0;
            let ok = true;
            while (j < nn) {
                if (*vector::borrow(hay, i + j) != *vector::borrow(needle, j)) {
                    ok = false;
                    break
                };
                j = j + 1;
            };
            if (ok) return true;
            i = i + 1;
        };
        false
    }

    // R2-C01 regression: zombie positions (initial=0) must have their snapshots
    // refreshed on every sp_settle call, not left stale. Otherwise a later
    // redeposit pairs a fresh initial_balance with a stale snap_product /
    // snap_index_one pair, inflating the next pending_one by Δindex / stale_P.
    #[test(deployer = @ONE)]
    fun test_zombie_redeposit_no_phantom_reward(deployer: &signer) {
        setup(deployer);
        let alice = @0xA11CE;

        // Seed a zombie: initial=0, stale snap_p far below current P,
        // stale snap_i_one / snap_i_coll far below current reward indices.
        ONE::test_set_sp_position(alice, 0, 100_000_000_000_000, 500, 500);
        ONE::test_force_reward_indices(1_000_000_000_000_000_000, 2_000_000_000_000_000_000);

        ONE::test_call_sp_settle(alice);

        // Fix validation: snaps must be refreshed to current registry state
        // so a subsequent redeposit cannot inherit the stale pre-zombie diff.
        let (initial, snap_p, snap_i_one, snap_i_coll) = ONE::test_get_sp_snapshots(alice);
        assert!(initial == 0, 900);
        assert!(snap_p == 1_000_000_000_000_000_000, 901);
        assert!(snap_i_one == 1_000_000_000_000_000_000, 902);
        assert!(snap_i_coll == 2_000_000_000_000_000_000, 903);
    }
}
```

---

## §4. Test suite

20/20 `aptos move test` pass on v0.1.2. Oracle paths are not unit-tested (Pyth is not easily mockable in the Move test VM); those are validated via integration testing on chain.

```
test_close_trove_without_trove_aborts
test_destroy_cap_consumes_resource
test_destroy_cap_double_call_aborts
test_destroy_cap_non_origin_aborts
test_init_creates_registry
test_liquidation_cliff_guard_aborts
test_liquidation_sequential_math
test_liquidation_single_depositor
test_liquidation_two_depositors_pro_rata
test_metadata_addr_stable
test_reward_index_increment_and_pending
test_reward_index_pro_rata_two_depositors
test_sp_claim_without_position_aborts
test_sp_deposit_zero_aborts
test_sp_of_unknown_returns_zero
test_sp_position_creation_via_helper
test_sp_withdraw_without_position_aborts
test_trove_of_unknown_returns_zero
test_warning_text_on_chain
test_zombie_redeposit_no_phantom_reward   <-- R2-C01 regression
```

### External refs

- Pyth Aptos mainnet package: `0x7e783b349d3e89cf5931af376ebeadbfab855b3fa239b7ada8f5a92fbea6b387` (immutable, auth_key = 0x0)
- APT/USD feed id: `0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5`
- VAA source: https://hermes.pyth.network/
- Repo: https://github.com/darbitex/ONE (root README documents Supra v0.3.0 deprecation for same C-01/M-01/L-01 bugs — Supra source is null-auth'd and cannot be patched)

---

## Output format

Per finding, please report:

- **Severity**: CRITICAL / HIGH / MEDIUM / LOW / INFO / NIT
- **Location**: `file:line` or function name
- **Issue** | **Impact** | **Recommendation** | **Confidence**
- **Reference**: if commenting on an R2 fix, reference its ID (R2-C01 / R2-M01 / R2-L01)

End with:
- Overall verdict: **GREEN / NEEDS FIX / NOT READY**
- Answers to Q1 and Q2 in §2
