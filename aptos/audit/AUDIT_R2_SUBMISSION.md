# ONE Stablecoin — Round 2 Audit Submission

**Version:** v0.1.1 (post R1 fix batch)
**Chain:** Aptos mainnet (Move 2)
**Philosophy:** Immutable post-`destroy_cap`. Real funds at stake.
**Warning embedded on-chain:** "one is immutable = bug is real."

---

## R2 ask

Review the **15 R1 fixes** against the full source below. Your job:

1. **Validate each R1 fix is correctly applied** — any regression, missed edge, or over-restrictive assertion?
2. **Weigh in on 3 deferred R1 design questions** (see §2)
3. **Fresh findings** from inspecting the modified code
4. Final verdict: GREEN / NEEDS FIX / NOT READY

Don't re-litigate items already applied — validate them. Skip baseline-carried math (Liquity-P, fee routing, FA handling) unless you spot a new regression.

---

## §1. R1 fix batch summary (all applied in this version)

All fixes below are in the full source attached at §3.

| # | Origin | Location | Change |
|---|---|---|---|
| 1 | Gemini #2 | `close_impl` | `if (t.debt > 0)` guard around `primary_fungible_store::withdraw` + `fungible_asset::burn` to avoid 0-amount FA ops |
| 2 | Gemini #3 | `price_8dec` | New const `E_EXPO_BOUND = 12`, assert `abs_e <= 18` to prevent pow10 overflow on absurd expo values |
| 3 | Kimi HIGH-1 | `STALENESS_SECS` | Tightened from 900s (15 min) to 60s to match Pyth's own best-practice guidance (reduce VAA cherry-pick window) |
| 4 | DeepSeek F-02 + Gemini/Claude consensus | `price_8dec` | Future-skew tolerance settled at 10s (started 5s → 30s → 10s through auditor reconciliation) |
| 5 | DeepSeek F-05 | `destroy_cap` | New `CapDestroyed` event emitted on consume for on-chain evidence of sealing |
| 6 | Grok #5 | views | New `#[view] is_sealed(): bool` returning `!exists<ResourceCap>(@ONE)` |
| 7 | Grok NIT | consts | Removed unused `LIQ_SP_DEPOSITOR_BPS = 5000` (SP gets remainder by subtraction, no reference needed) |
| 8 | Claude H-01 | `price_8dec` | New `MAX_CONF_BPS = 200` (2% cap), new `E_PRICE_UNCERTAIN = 19`, `conf/raw` ratio assert. Rejects Pyth prices with wide confidence interval (flash-crash/outage signal) |
| 9 | Claude M-05 | views | New `#[view] close_cost(addr): u64` returning target's debt — front-end helper for the structural 1% close deficit |
| 10 | Claude M-01 | entries | 4 atomic `*_pyth` wrappers (`open_trove_pyth`, `redeem_pyth`, `redeem_from_reserve_pyth`, `liquidate_pyth`) that call `pyth::update_price_feeds_with_funder(user, vaas)` before the business logic, eliminating 2-tx integrator footgun |
| 11 | Claude M-04 | `sp_deposit` | `if (r.total_sp == 0) { r.product_factor = PRECISION; };` — reset-on-empty. Converts the terminal SP-cliff-frozen state into a transient one: once all depositors exit, next deposit re-baselines P. Critical for immutable protocol recovery. |
| 12 | Claude M-06 | `sp_settle` | Saturate pending rewards at `u64::MAX` (via u256 intermediates) rather than abort. Prevents permanent SP position lock on asymptotic overflow over decades of accrual |
| 13 | Claude M-07 | `WARNING` const | Rewrote limitation (3) to accurately describe liquidation priority order: liquidator first (capped), reserve second, SP absorbs remainder + debt burn. Previously implied liq+reserve always retain nominal; reality is liquidator gets entire collateral at extreme CR |
| 14 | Claude L-04 | views | New `#[view] trove_health(addr): (u64, u64, u64)` returning (collateral, debt, cr_bps) — calls `price_8dec()`, inherits its abort semantics |
| 15 | ChatGPT #6 | `sp_settle` + events | New `RewardSaturated` event emitted when u64 truncation occurs — on-chain visibility of silent cap |

**False positives rejected** (submitted for your awareness, no action taken):
- Kimi CRIT-1 u128 overflow — ignored `as u256` intermediates; u64 final cast is intentional and saturated (fix 12 above)
- DeepSeek F-03 SP-empty burn "undefined" — actual code has explicit `if (r.total_sp == 0) { burn }` branch (auditor saw excerpt only)
- Qwen F-1/F-2 liquidation no caps / div-by-zero — same excerpt-only mistake
- Claude markdown-only H-03 staleness=900s — saw stale submission doc (already fixed to 60s)
- ChatGPT #1 `total_sp > debt` → `>=` — cliff guard already catches `total_sp == debt` with E_P_CLIFF; strict `>` kept for clearer error attribution

**Spec-level items deferred to R2 (§2):**
- Liquidation SP-priority at extreme CR (4/7 auditors flagged)
- MIN_DEBT raise (Claude M-03 argument for $100-1000 min)
- (SP cliff reset was Claude M-04 → already applied as fix 11; please verify non-regression)

---

## §2. Three R2 design questions

### Q1 — Liquidation priority at extreme CR

Current code (see `liquidate` body in §3): liquidator bonus first (capped at `total_seize_coll`), then reserve (capped at remaining), SP gets the residual collateral + absorbs the full debt burn from `sp_pool`.

At CR ≈ 150% (normal liquidation): nominal 25/50/25 split holds.
At CR ≈ 110%: shortfall starts; SP receives less than 50% of debt value but still > 0.
At CR ≈ 5%: liquidator takes the entire seized collateral, reserve and SP get zero, SP still burns `debt` ONE from `sp_pool`.

**Auditors flagging this**: Kimi HIGH-2, Qwen F-1, Grok CRIT #1, ChatGPT #2. Suggested alternatives:
- **Option A — current**: liquidator priority (ensures liquidation always incentivized, even at extreme CR)
- **Option B — SP priority**: SP gets debt-worth first, then liquidator + reserve split remainder (protects SP from extreme loss)
- **Option C — proportional**: all three shares scale down proportionally when collateral insufficient (preserves 25/50/25 ratio but reduces absolute liquidator reward)
- **Option D — hard CR floor**: abort liquidation if CR below some threshold (e.g. 105%); bad debt accumulates, never absorbed

The current design (Option A) was explicit: it prioritizes "liquidation engine always has an economic caller" over "SP never loses disproportionately." At CR=2%, attacker self-liquidating their own trove could extract liq share of their own nearly-worthless collateral while SP eats the debt.

**Your input wanted**: which option, and why?

### Q2 — MIN_DEBT raise

Current: `MIN_DEBT = 100_000_000` = 1 ONE = $1. Claude M-03 argued this enables dust-trove DoS (liquidator bonus for a 1-ONE trove is $0.025 — below any plausible gas cost, so dust troves become permanent bad debt).

Liquity historically used $2000 minimum. DeFi production norms range $100-$2000.

Trade-off: raising MIN_DEBT to 100 ONE ($100) or 1000 ONE ($1000) protects against dust attacks but increases user entry friction 100-1000×.

**Your input wanted**: keep 1 ONE, raise to 100, raise to 1000, or other — and why?

### Q3 — SP cliff reset-on-empty (applied as fix 11, verify)

In `sp_deposit`:
```move
if (r.total_sp == 0) {
    r.product_factor = PRECISION;
};
```

Rationale: post-cliff state (where `product_factor` approaches `MIN_P_THRESHOLD = 1e9`) is terminal — any further liquidation aborts via cliff guard, bad debt accumulates. If all depositors eventually exit (bringing `total_sp` to 0), next depositor would inherit the near-cliff P and still have no liquidation capacity. Reset-on-empty converts this terminal state to transient.

`reward_index_one` and `reward_index_coll` are intentionally NOT reset — new depositor's snapshot is set to current indices at sp_deposit time, so relative-delta math still works. No retroactive rewards.

**Your input wanted**: is this reset safe? Are there attack vectors where someone deliberately drains SP to trigger a reset and exploit it?

---

## §3. Full source

### Move.toml

```toml
[package]
name = "ONE"
version = "0.1.0"
upgrade_policy = "compatible"

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

    const WARNING: vector<u8> = b"ONE is an immutable stablecoin contract on Aptos that depends on Pyth Network's on-chain price feed for APT/USD. If Pyth degrades or misrepresents its oracle, ONE's peg mechanism breaks deterministically - users can wind down via self-close without any external assistance, but new mint/redeem operations become unreliable or frozen. one is immutable = bug is real. Audit this code yourself before interacting. KNOWN LIMITATIONS: (1) Stability Pool enters frozen state when product_factor would drop below 1e9 - protocol aborts further liquidations rather than corrupt SP accounting, accepting bad-debt accumulation past the threshold. (2) Sustained large-scale activity over decades may asymptotically exceed u64 bounds on pending SP rewards. (3) Liquidation seized collateral is distributed in priority: liquidator bonus first (nominal 25% of debt value), then 25% reserve share, then SP absorbs the remainder and the debt burn. At CR roughly 110% to 150% the SP alone covers the collateral shortfall. At CR below ~5% the liquidator may take the entire remaining collateral, reserve and SP receive zero, and SP still absorbs the full debt burn. (4) 25 percent of each fee is burned, creating a structural 0.25 percent aggregate supply-vs-debt gap per cycle (which rises to 1 percent during SP-empty windows because the remaining 75 percent also burns); individual debtors also face a 1 percent per-trove shortfall because only 99 percent is minted while 100 percent is needed to close - full protocol wind-down requires secondary-market ONE for the last debt closure. (5) Self-redemption (redeem against own trove) is allowed and behaves as partial debt repayment plus collateral withdrawal with a 1 percent fee. (6) Pyth is pull-based on Aptos - callers must ensure price is fresh (within 60 seconds) via pyth::update_price_feeds VAA update before invoking any ONE entry that reads the oracle. (7) Extreme low-price regimes may cause transient aborts in redeem paths when requested amounts exceed u64 output bounds; use smaller amounts and retry. (8) PERMANENT ORACLE FREEZE: if the Pyth package at 0x7e78... is upgraded in a breaking way, the APT/USD feed id 0x03ae4d... is de-registered, or the feed ever becomes permanently unavailable for any reason, the oracle-dependent entries (open_trove, redeem, liquidate, redeem_from_reserve, and their *_pyth wrappers) abort permanently. Oracle-free escape hatches remain fully open: close_trove lets any trove owner reclaim their collateral by burning the full trove debt in ONE (acquiring the 1 percent close deficit via secondary market if needed); add_collateral lets owners top up existing troves without touching the oracle; sp_deposit, sp_withdraw, and sp_claim let SP depositors manage and exit their positions and claim any rewards accumulated before the freeze. Protocol-owned APT held in reserve_coll becomes permanently locked because redeem_from_reserve requires the oracle. No admin override exists; the freeze is final.";

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
        if (snap_p == 0 || initial == 0) return;

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
}

```

### External refs

- Pyth Aptos mainnet package: `0x7e783b349d3e89cf5931af376ebeadbfab855b3fa239b7ada8f5a92fbea6b387` (immutable, auth_key = 0x0)
- APT/USD feed id: `0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5`
- VAA source: https://hermes.pyth.network/

### Tests

19/19 `aptos move test` pass. Oracle paths not unit-tested (Pyth not easily mockable in Move test VM); validated via integration testing on chain.

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
```

---

## Output format

Structured report per finding:

- **Severity**: CRITICAL / HIGH / MEDIUM / LOW / INFO / NIT
- **Location**: `file:line` or function name
- **Issue** | **Impact** | **Recommendation** | **Confidence**
- **Fix-number reference**: if commenting on an R1 fix (from §1), reference its number for cross-check

End with overall verdict: **GREEN / NEEDS FIX / NOT READY**.

And please answer the three design questions in §2.
