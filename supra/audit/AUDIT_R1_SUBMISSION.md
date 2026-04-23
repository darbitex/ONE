# ONE Stablecoin — Round 1 Audit Submission

**Version:** v0.3.2
**Target chain:** Supra L1 mainnet (testnet already deployed + null-auth'd at `0x94d77edd...`)
**Language:** Move
**Philosophy:** Purist immutable, no governance, no admin, no upgrade after null-auth
**Warning embedded on-chain:** "one is immutable = bug is real. made by solo dev and claude ai"

---

## Audit scope & request

You are auditing a Move-language stablecoin protocol named ONE, designed for Supra L1. The protocol is permissionlessly-usable, fully autonomous, and will be published with `upgrade_policy = "compatible"` then rotated to null auth_key so nobody can ever upgrade the code. Once live, any bug is permanent — there is no governance, no admin, no pause, no upgrade path.

Review as if real user funds are at stake. Specifically focus on:

### 1. Math correctness
- **Liquity-P mechanism**: `product_factor` + dual `reward_index` (ONE fees + SUPRA from liquidations). Verify formula conservation across deposit/withdraw/liquidation/fee sequences. Check product_factor precision decay scenarios.
- **Fee split**: 1% mint + 1% redeem fees. Of the fee: 25% burned (supply deflation), 75% distributed to SP via `reward_index_one`.
- **Liquidation split 25/50/25**: 25% of bonus to liquidator (SUPRA), 50% of bonus to SP depositors (SUPRA via reward_index_supra), 25% of bonus accumulates permanently in `reserve_supra` pool.
- **Debt + bonus extraction math**: total_seize_supra = debt_usd + bonus_usd, converted via oracle price, capped at target collateral. Downstream splits must not underflow.
- **u128/u256 overflow**: particularly in sp_settle (`delta * balance / snap_p`) and reward_index updates (`amount * P / total_sp`).

### 2. Liquidation economics
- Open MCR = 200%, liq threshold = 150%. Liq triggers when SUPRA price drops ~25% from open.
- Liquidator incentive: 25% of bonus = 2.5% of debt (USD value). Is this enough for economic rationality?
- SP depositor economics: absorbs debt worth of SUPRA + 50% of bonus. Comes out 5% profit per liquidation. Verify absorption capacity math.
- Edge case: `total_sp` just barely larger than `debt` — should assertion be `>` strict (current) or `>=`?

### 3. Oracle trust surface
- Oracle is Supra's native `supra_oracle_storage` at `0xe3948c9e...4150` (mainnet) / `0x5615001f...` (testnet). Pair 500 = SUPRA/USDT.
- Staleness check: `timestamp::now_seconds() * 1000 <= ts_ms + 3_600_000` (1 hour window). Oracle timestamp in EPOCH MS, Move timestamp in seconds.
- What happens if oracle is manipulated mid-tx? What's the blast radius given 200% MCR?
- Trust inheritance: protocol only as trustworthy as the oracle feed behind pair 500 + Supra Foundation's operational commitments.

### 4. Reentrancy
- Move VM structurally prevents reentrancy (no callbacks, no fallback fns, single-threaded within tx, exclusive `&mut` borrows).
- But: any case where an external call's return could create a window? e.g., `primary_fungible_store::deposit` or `fungible_asset::withdraw_with_ref` triggering user-controlled dispatch?
- ONE FA has no dispatch functions registered, but SUPRA FA (at `@0xa`) — verify it cannot reenter our module.

### 5. Supply invariants
- Mint: supply += debt - fee_burned_portion. Fee routing to SP or burn.
- Redeem: supply -= (net_burned + fee_burned).
- Liquidation: supply -= debt (absorbed by SP).
- close_trove: supply -= t.debt.
- redeem_from_reserve: supply -= one_amt (net + fee).
- Verify: at all times, total ONE supply ≤ sum of all trove debts + protocol-owned positions, but NEVER more than backing capacity.

### 6. Edge cases
- `sp_settle` when `initial_balance = 0` or `snapshot_product = 0`
- `sp_withdraw` dropping position to zero → removes from table
- `product_factor` approaching precision loss (many sequential liquidations)
- `reserve_redeem` when `reserve_supra.balance < supra_out` (hard assertion, cannot partial)
- Multiple `liquidate` in same block against same target — second fails (trove already removed)
- `open_trove` with `supra_amt = 0` on existing trove (allowed by design for debt-only increase)
- `close_trove` when user wallet ONE < trove debt (should abort with underflow from primary store withdraw)
- SUPRA oracle value of 0 (would cause div-by-zero in `supra_out = net * 1e8 / price`)

### 7. Bootstrap + null auth safety
- Deployer bootstraps genesis trove, deposits to SP (optional), then rotates auth_key to 0x0.
- Post-null-auth: deployer's Registry resource still exists with MintRef/BurnRef/ExtendRef. Protocol continues because public entry fns use `borrow_global<Registry>(@ONE)` permissionlessly.
- Deployer's genesis trove is STUCK — cannot self-close (can't acquire missing 0.01 ONE from fee burn). Acceptable acyclic sink?
- What if deployer loses control of auth key BEFORE null_auth? Deployer could do arbitrary transfers from own account (but not upgrade, thanks to compatible + null-pending).

### 8. Immutability guarantees
- `upgrade_policy = "compatible"` required because deps (SupraFramework, dora) are compatible.
- True immutability via null auth_key: no signer can call `0x1::code::publish_package_txn` for the deployer.
- Governance risk: Supra Foundation could theoretically hardfork framework OR update oracle module. Protocol inherits this. Documented in on-chain WARNING constant.

### 9. Critical constants locked forever
All these are hardcoded at deploy — cannot be changed. Any that should be parameterized?

```move
MCR_BPS             = 20000  // 200%
LIQ_THRESHOLD_BPS   = 15000  // 150%
LIQ_BONUS_BPS       = 1000   // 10% of debt
LIQ_LIQUIDATOR_BPS  = 2500   // 25% of bonus
LIQ_SP_DEPOSITOR_BPS = 5000  // 50% of bonus
LIQ_SP_RESERVE_BPS  = 2500   // 25% of bonus
FEE_BPS             = 100    // 1% mint/redeem
PAIR_ID             = 500    // SUPRA/USDT
STALENESS_MS        = 3_600_000  // 1 hour
MIN_DEBT            = 100_000_000  // 1 ONE minimum
PRECISION           = 1e18
SUPRA_FA            = @0xa
```

### 10. What you should produce

A structured report per finding, with:
- **Severity**: CRITICAL / HIGH / MEDIUM / LOW / INFO / NIT
- **Location**: `file:line` or function name
- **Issue**: What's wrong or suspect
- **Impact**: What could go wrong in practice
- **Recommendation**: Specific fix if applicable
- **Confidence**: your certainty level

At the end, provide overall verdict: **PROCEED TO PUBLISH / NEEDS FIX BATCH / NOT READY**.

---

## Protocol specification summary

### Identity
- Name: ONE
- Ticker: 1
- Decimals: 8
- Peg target: $1 USD (via SUPRA/USDT oracle pair)

### Collateral
- SUPRA only (native L1 token), FA-form accepted (not Coin<SupraCoin>)
- User must migrate Coin→FA externally before interacting (one-way Supra framework direction)

### Economic parameters (locked forever at deploy)
```
Open MCR             : 200% (minimum collateral ratio at trove open)
Liquidation threshold: 150% (below this CR, trove liquidatable)
Liquidation bonus    : 10% of debt (from target's collateral)
  → 25% to liquidator (SUPRA)
  → 50% to SP depositors (SUPRA, via reward_index_supra)
  → 25% to reserve_supra pool (permanent)
Mint fee             : 1% of debt
  → 25% burned (supply deflation)
  → 75% to SP (via reward_index_one, or burned if SP empty)
Redeem fee           : 1% of one_amt (same split as mint)
Min debt per trove   : 1 ONE
Oracle staleness     : 1 hour
SP absorption        : Liquity-P (product_factor + dual reward index)
```

### Entry functions (8 public)
```
open_trove(user, supra_amt, debt)         — deposit FA SUPRA, mint ONE
add_collateral(user, supra_amt)           — top up without minting
close_trove(user)                          — burn debt, unlock all collateral (oracle-free)
redeem(user, one_amt, target)             — burn ONE for $1 worth SUPRA from target trove
redeem_from_reserve(user, one_amt)        — burn ONE for SUPRA from protocol reserve
liquidate(liquidator, target)             — absorb underwater trove (CR < 150%)
sp_deposit(user, amt)                      — lock ONE in SP for yield
sp_withdraw(user, amt)                     — exit SP (settles pending first)
sp_claim(user)                             — claim pending rewards only
```

### View functions (7)
```
read_warning() → vector<u8>                — on-chain warning text
metadata_addr() → address                  — ONE FA metadata addr
price() → u128                              — SUPRA/USDT at 8 decimals
trove_of(addr) → (u64, u64)                — (collateral, debt)
sp_of(addr) → (u64, u64, u64)              — (balance, pending_one, pending_supra)
totals() → (u64, u64, u128, u128, u128)    — (total_debt, total_sp, product_factor, reward_index_one, reward_index_supra)
reserve_balance() → u64                     — SUPRA in permanent reserve pool
```

### On-chain warning (immutable const)
> ONE is an immutable stablecoin contract that depends on Supra's native oracle feed. If Supra Foundation ever degrades or misrepresents its oracle, ONE's peg mechanism breaks deterministically - users can wind down via self-close without any external assistance, but new mint/redeem operations become unreliable or frozen. one is immutable = bug is real. Audit this code yourself before interacting. made by solo dev and claude ai

---

## Full source code

Module published at `0x94d77edd433375961f67f69fba88a797eb7b971b46554293230fa807a4e9e0aa::ONE` on Supra testnet.

Compile command (Aptos CLI 9.1.0):
```bash
aptos move compile --bytecode-version 6 --language-version 1 --named-addresses ONE=<deployer>
```

Move.toml:
```toml
[package]
name = "ONE"
version = "0.1.0"
upgrade_policy = "compatible"

[addresses]
ONE = "_"

[dependencies]
SupraFramework = { git = "https://github.com/Entropy-Foundation/aptos-core.git", subdir = "aptos-move/framework/supra-framework", rev = "dev" }
core = { git = "https://github.com/Entropy-Foundation/dora-interface.git", subdir = "supra/mainnet/core", rev = "master" }
```

### sources/ONE.move (559 lines)

```move
/// ONE — immutable stablecoin on Supra L1
///
/// WARNING: ONE is an immutable stablecoin contract that depends on
/// Supra's native oracle feed. If Supra Foundation ever degrades or
/// misrepresents its oracle, ONE's peg mechanism breaks deterministically
/// - users can wind down via self-close without any external assistance,
/// but new mint/redeem operations become unreliable or frozen.
/// one is immutable = bug is real. Audit this code yourself before
/// interacting. made by solo dev and claude ai
module ONE::ONE {
    use std::option;
    use std::signer;
    use std::string;
    use aptos_std::smart_table::{Self, SmartTable};
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, MintRef, BurnRef, Metadata};
    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use supra_oracle::supra_oracle_storage;

    // --- spec constants (locked forever) ---
    const MCR_BPS: u128 = 20000;                      // 200% Open MCR
    const LIQ_THRESHOLD_BPS: u128 = 15000;            // 150% liquidation threshold
    const LIQ_BONUS_BPS: u64 = 1000;                  // 10% bonus of debt
    const LIQ_LIQUIDATOR_BPS: u64 = 2500;             // 25% of bonus to liquidator
    const LIQ_SP_DEPOSITOR_BPS: u64 = 5000;           // 50% of bonus to SP depositors (via reward_index_supra)
    const LIQ_SP_RESERVE_BPS: u64 = 2500;             // 25% of bonus to permanent SP reserve (SUPRA-only)
    const FEE_BPS: u64 = 100;                         // 1% mint+redeem fee
    const PAIR_ID: u32 = 500;                         // SUPRA/USDT
    const STALENESS_MS: u64 = 3_600_000;              // 1 hour
    const MIN_DEBT: u64 = 100_000_000;                // 1 ONE (8 dec)
    const PRECISION: u128 = 1_000_000_000_000_000_000;// 1e18 for reward indices + product factor
    const SUPRA_FA: address = @0xa;                   // paired FA metadata of SupraCoin

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

    const WARNING: vector<u8> = b"ONE is an immutable stablecoin contract that depends on Supra's native oracle feed. If Supra Foundation ever degrades or misrepresents its oracle, ONE's peg mechanism breaks deterministically - users can wind down via self-close without any external assistance, but new mint/redeem operations become unreliable or frozen. one is immutable = bug is real. Audit this code yourself before interacting. made by solo dev and claude ai";

    struct Trove has store, drop { collateral: u64, debt: u64 }
    struct SP has store, drop {
        initial_balance: u64,
        snapshot_product: u128,
        snapshot_index_one: u128,
        snapshot_index_supra: u128,
    }

    struct Registry has key {
        metadata: Object<Metadata>,
        supra_metadata: Object<Metadata>,
        mint_ref: MintRef,
        burn_ref: BurnRef,
        fee_pool: Object<FungibleStore>,
        fee_extend: ExtendRef,
        sp_pool: Object<FungibleStore>,
        sp_extend: ExtendRef,
        sp_supra_pool: Object<FungibleStore>,
        sp_supra_extend: ExtendRef,
        reserve_supra: Object<FungibleStore>,        // permanent protocol-owned SUPRA, grows per liq
        reserve_extend: ExtendRef,
        treasury: Object<FungibleStore>,
        treasury_extend: ExtendRef,
        troves: SmartTable<address, Trove>,
        sp_positions: SmartTable<address, SP>,
        total_debt: u64,
        total_sp: u64,
        product_factor: u128,      // Liquity-P scaling, starts at PRECISION
        reward_index_one: u128,    // cumulative ONE fee per unit SP stake, scaled
        reward_index_supra: u128,  // cumulative SUPRA liquidation gain per unit SP stake, scaled
    }

    // --- events ---
    #[event] struct TroveOpened has drop, store { user: address, new_collateral: u64, new_debt: u64, added_debt: u64 }
    #[event] struct CollateralAdded has drop, store { user: address, amount: u64 }
    #[event] struct TroveClosed has drop, store { user: address, collateral: u64, debt: u64 }
    #[event] struct Redeemed has drop, store { user: address, target: address, one_amt: u64, supra_out: u64 }
    #[event] struct Liquidated has drop, store { liquidator: address, target: address, debt: u64, supra_to_liquidator: u64, supra_to_sp: u64, supra_to_reserve: u64, supra_to_target: u64 }
    #[event] struct SPDeposited has drop, store { user: address, amount: u64 }
    #[event] struct SPWithdrew has drop, store { user: address, amount: u64 }
    #[event] struct SPClaimed has drop, store { user: address, one_amt: u64, supra_amt: u64 }
    #[event] struct ReserveRedeemed has drop, store { user: address, one_amt: u64, supra_out: u64 }
    #[event] struct FeeBurned has drop, store { amount: u64 }

    fun init_module(deployer: &signer) {
        init_module_inner(deployer, object::address_to_object<Metadata>(SUPRA_FA));
    }

    fun init_module_inner(deployer: &signer, supra_md: Object<Metadata>) {
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
        let sp_supra_ctor = object::create_object(da);
        let reserve_ctor = object::create_object(da);
        let tr_ctor = object::create_object(da);
        move_to(deployer, Registry {
            metadata,
            supra_metadata: supra_md,
            mint_ref: fungible_asset::generate_mint_ref(&ctor),
            burn_ref: fungible_asset::generate_burn_ref(&ctor),
            fee_pool: fungible_asset::create_store(&fee_ctor, metadata),
            fee_extend: object::generate_extend_ref(&fee_ctor),
            sp_pool: fungible_asset::create_store(&sp_ctor, metadata),
            sp_extend: object::generate_extend_ref(&sp_ctor),
            sp_supra_pool: fungible_asset::create_store(&sp_supra_ctor, supra_md),
            sp_supra_extend: object::generate_extend_ref(&sp_supra_ctor),
            reserve_supra: fungible_asset::create_store(&reserve_ctor, supra_md),
            reserve_extend: object::generate_extend_ref(&reserve_ctor),
            treasury: fungible_asset::create_store(&tr_ctor, supra_md),
            treasury_extend: object::generate_extend_ref(&tr_ctor),
            troves: smart_table::new(),
            sp_positions: smart_table::new(),
            total_debt: 0,
            total_sp: 0,
            product_factor: PRECISION,
            reward_index_one: 0,
            reward_index_supra: 0,
        });
    }

    // =========================================================
    //                      INTERNAL HELPERS
    // =========================================================

    fun price_8dec(): u128 {
        let (v, d, ts_ms, _) = supra_oracle_storage::get_price(PAIR_ID);
        assert!(timestamp::now_seconds() * 1000 <= ts_ms + STALENESS_MS, E_STALE);
        let dec = (d as u64);
        if (dec >= 8) v / pow10(dec - 8) else v * pow10(8 - dec)
    }

    fun pow10(n: u64): u128 {
        let r: u128 = 1;
        while (n > 0) { r = r * 10; n = n - 1; };
        r
    }

    /// Route fee to SP reward pool (or burn if SP empty). Updates reward_index_one per Liquity-P formula.
    fun route_fee_fa(r: &mut Registry, fa: FungibleAsset) {
        let amt = fungible_asset::amount(&fa);
        if (amt == 0) { fungible_asset::destroy_zero(fa); return };
        // 25% of every fee burned (supply deflation = implicit reserve contribution)
        let burn_amt = amt * 2500 / 10000;
        if (burn_amt > 0) {
            let burn_portion = fungible_asset::extract(&mut fa, burn_amt);
            fungible_asset::burn(&r.burn_ref, burn_portion);
            event::emit(FeeBurned { amount: burn_amt });
        };
        // Remaining 75% to SP (or burn if SP empty)
        let sp_amt = fungible_asset::amount(&fa);
        if (sp_amt == 0) { fungible_asset::destroy_zero(fa); return };
        if (r.total_sp == 0) {
            fungible_asset::burn(&r.burn_ref, fa);
        } else {
            fungible_asset::deposit(r.fee_pool, fa);
            r.reward_index_one = r.reward_index_one + (sp_amt as u128) * r.product_factor / (r.total_sp as u128);
        }
    }

    /// Settle pending rewards (ONE + SUPRA) for a user. Updates snapshots and effective balance.
    fun sp_settle(r: &mut Registry, u: address) {
        let pos = smart_table::borrow_mut(&mut r.sp_positions, u);
        let snap_p = pos.snapshot_product;
        let snap_i_one = pos.snapshot_index_one;
        let snap_i_supra = pos.snapshot_index_supra;
        let initial = pos.initial_balance;

        if (snap_p == 0 || initial == 0) return;

        // Compute pending (u256 to prevent overflow at high index × balance)
        let pending_one = ((((r.reward_index_one - snap_i_one) as u256) * (initial as u256)) / (snap_p as u256)) as u64;
        let pending_supra = ((((r.reward_index_supra - snap_i_supra) as u256) * (initial as u256)) / (snap_p as u256)) as u64;

        // Update effective balance: balance decays with product ratio
        let new_balance = ((((initial as u256) * (r.product_factor as u256)) / (snap_p as u256)) as u64);
        pos.initial_balance = new_balance;
        pos.snapshot_product = r.product_factor;
        pos.snapshot_index_one = r.reward_index_one;
        pos.snapshot_index_supra = r.reward_index_supra;

        if (pending_one > 0) {
            let fee_signer = object::generate_signer_for_extending(&r.fee_extend);
            let fa = fungible_asset::withdraw(&fee_signer, r.fee_pool, pending_one);
            primary_fungible_store::deposit(u, fa);
        };
        if (pending_supra > 0) {
            let supra_signer = object::generate_signer_for_extending(&r.sp_supra_extend);
            let fa = fungible_asset::withdraw(&supra_signer, r.sp_supra_pool, pending_supra);
            primary_fungible_store::deposit(u, fa);
        };
        if (pending_one > 0 || pending_supra > 0) {
            event::emit(SPClaimed { user: u, one_amt: pending_one, supra_amt: pending_supra });
        }
    }

    fun open_impl(user_addr: address, fa_coll: FungibleAsset, debt: u64) acquires Registry {
        assert!(debt >= MIN_DEBT, E_DEBT_MIN);
        let supra_amt = fungible_asset::amount(&fa_coll);
        let r = borrow_global_mut<Registry>(@ONE);
        let price = price_8dec();

        let is_existing = smart_table::contains(&r.troves, user_addr);
        let (prior_coll, prior_debt) = if (is_existing) {
            let t = smart_table::borrow(&r.troves, user_addr);
            (t.collateral, t.debt)
        } else (0, 0);
        let new_coll = prior_coll + supra_amt;
        let new_debt = prior_debt + debt;
        let coll_usd = (new_coll as u128) * price / 100_000_000;
        // Open MCR check: coll_usd / debt >= MCR_BPS/10000 → coll_usd * 10000 >= MCR_BPS * debt
        assert!(coll_usd * 10000 >= MCR_BPS * (new_debt as u128), E_COLLATERAL);

        fungible_asset::deposit(r.treasury, fa_coll);
        let fee = debt * FEE_BPS / 10000;
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
        fungible_asset::burn(&r.burn_ref, primary_fungible_store::withdraw(user, r.metadata, t.debt));
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
        let fee = one_amt * FEE_BPS / 10000;
        let net = one_amt - fee;
        let supra_out = (((net as u128) * 100_000_000 / price) as u64);

        let t = smart_table::borrow_mut(&mut r.troves, target);
        assert!(t.debt >= net, E_TARGET);
        assert!(t.collateral >= supra_out, E_COLLATERAL);
        t.debt = t.debt - net;
        t.collateral = t.collateral - supra_out;

        let user_fa = primary_fungible_store::withdraw(user, r.metadata, one_amt);
        let fee_fa = fungible_asset::extract(&mut user_fa, fee);
        fungible_asset::burn(&r.burn_ref, user_fa);
        route_fee_fa(r, fee_fa);
        r.total_debt = r.total_debt - net;
        let u = signer::address_of(user);
        event::emit(Redeemed { user: u, target, one_amt, supra_out });
        let sr = object::generate_signer_for_extending(&r.treasury_extend);
        fungible_asset::withdraw(&sr, r.treasury, supra_out)
    }

    // =========================================================
    //                           ENTRIES
    //            FA-only symmetric — purist immutable
    // =========================================================

    public entry fun open_trove(user: &signer, supra_amt: u64, debt: u64) acquires Registry {
        let supra_md = borrow_global<Registry>(@ONE).supra_metadata;
        let fa = primary_fungible_store::withdraw(user, supra_md, supra_amt);
        open_impl(signer::address_of(user), fa, debt);
    }

    public entry fun add_collateral(user: &signer, supra_amt: u64) acquires Registry {
        let supra_md = borrow_global<Registry>(@ONE).supra_metadata;
        let fa = primary_fungible_store::withdraw(user, supra_md, supra_amt);
        add_impl(signer::address_of(user), fa);
    }

    /// Close own trove. Oracle-FREE — safe wind-down if oracle breaks.
    public entry fun close_trove(user: &signer) acquires Registry {
        primary_fungible_store::deposit(signer::address_of(user), close_impl(user));
    }

    /// Redeem ONE against any trove at oracle price.
    public entry fun redeem(user: &signer, one_amt: u64, target: address) acquires Registry {
        primary_fungible_store::deposit(
            signer::address_of(user), redeem_impl(user, one_amt, target)
        );
    }

    /// Redeem ONE against the protocol reserve pool at oracle price.
    /// Hard peg floor mechanism — always available while reserve has SUPRA.
    /// Fee 1% (same as trove-redeem), routed to SP (or burned if SP empty).
    public entry fun redeem_from_reserve(user: &signer, one_amt: u64) acquires Registry {
        assert!(one_amt >= MIN_DEBT, E_AMOUNT);
        let r = borrow_global_mut<Registry>(@ONE);
        let price = price_8dec();
        let fee = one_amt * FEE_BPS / 10000;
        let net = one_amt - fee;
        let supra_out = (((net as u128) * 100_000_000 / price) as u64);
        assert!(fungible_asset::balance(r.reserve_supra) >= supra_out, E_INSUFFICIENT_RESERVE);

        let user_fa = primary_fungible_store::withdraw(user, r.metadata, one_amt);
        let fee_fa = fungible_asset::extract(&mut user_fa, fee);
        fungible_asset::burn(&r.burn_ref, user_fa);
        route_fee_fa(r, fee_fa);

        let sr = object::generate_signer_for_extending(&r.reserve_extend);
        let out = fungible_asset::withdraw(&sr, r.reserve_supra, supra_out);
        primary_fungible_store::deposit(signer::address_of(user), out);

        event::emit(ReserveRedeemed { user: signer::address_of(user), one_amt, supra_out });
    }

    /// Liquidate under-collateralized trove. Permissionless. SP absorbs.
    /// Target must have CR < 150%. SP must have total_sp >= target.debt.
    /// Bonus (10% of debt) split: 25% liquidator / 50% SP depositors / 25% reserve.
    public entry fun liquidate(liquidator: &signer, target: address) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        assert!(smart_table::contains(&r.troves, target), E_TARGET);
        let price = price_8dec();
        let t_ref = smart_table::borrow(&r.troves, target);
        let debt = t_ref.debt;
        let coll = t_ref.collateral;
        let coll_usd = (coll as u128) * price / 100_000_000;

        // Liquidatable: CR < LIQ_THRESHOLD_BPS / 10000
        assert!(coll_usd * 10000 < LIQ_THRESHOLD_BPS * (debt as u128), E_HEALTHY);
        // Strict >: prevents product_factor = 0 (full SP depletion breaks subsequent div).
        assert!(r.total_sp > debt, E_SP_INSUFFICIENT);

        // Compute seizure amounts (all in USD 8-dec terms, then convert to SUPRA raw)
        let bonus_usd = (debt as u128) * (LIQ_BONUS_BPS as u128) / 10000;
        let liq_share_usd = bonus_usd * (LIQ_LIQUIDATOR_BPS as u128) / 10000;
        let reserve_share_usd = bonus_usd * (LIQ_SP_RESERVE_BPS as u128) / 10000;
        let total_seize_usd = (debt as u128) + bonus_usd;
        let total_seize_supra = ((total_seize_usd * 100_000_000 / price) as u64);
        let total_seize_supra = if (total_seize_supra > coll) coll else total_seize_supra;
        let liq_supra = ((liq_share_usd * 100_000_000 / price) as u64);
        let liq_supra = if (liq_supra > total_seize_supra) total_seize_supra else liq_supra;
        let reserve_supra = ((reserve_share_usd * 100_000_000 / price) as u64);
        let reserve_supra = if (reserve_supra > total_seize_supra - liq_supra)
            total_seize_supra - liq_supra else reserve_supra;
        let sp_supra = total_seize_supra - liq_supra - reserve_supra;  // = debt_worth + 50% bonus
        let target_remainder = coll - total_seize_supra;

        // Remove trove + update debt
        smart_table::remove(&mut r.troves, target);
        r.total_debt = r.total_debt - debt;

        // Burn debt from sp_pool (Liquity-P style)
        let sp_signer = object::generate_signer_for_extending(&r.sp_extend);
        let burn_fa = fungible_asset::withdraw(&sp_signer, r.sp_pool, debt);
        fungible_asset::burn(&r.burn_ref, burn_fa);

        // Liquity-P state update: S_supra += sp_supra * P_current / total_nominal, THEN P *= (total-debt)/total
        let total_before = r.total_sp;
        r.reward_index_supra = r.reward_index_supra +
            (sp_supra as u128) * r.product_factor / (total_before as u128);
        r.product_factor = r.product_factor * ((total_before - debt) as u128) / (total_before as u128);
        r.total_sp = total_before - debt;

        // Seize SUPRA from treasury, distribute: liquidator, reserve, SP depositors
        let tr_signer = object::generate_signer_for_extending(&r.treasury_extend);
        let seized = fungible_asset::withdraw(&tr_signer, r.treasury, total_seize_supra);
        let liq_fa = fungible_asset::extract(&mut seized, liq_supra);
        primary_fungible_store::deposit(signer::address_of(liquidator), liq_fa);
        let reserve_fa = fungible_asset::extract(&mut seized, reserve_supra);
        fungible_asset::deposit(r.reserve_supra, reserve_fa);
        fungible_asset::deposit(r.sp_supra_pool, seized);  // remainder = sp_supra

        if (target_remainder > 0) {
            let rem_fa = fungible_asset::withdraw(&tr_signer, r.treasury, target_remainder);
            primary_fungible_store::deposit(target, rem_fa);
        };

        event::emit(Liquidated {
            liquidator: signer::address_of(liquidator),
            target, debt,
            supra_to_liquidator: liq_supra,
            supra_to_sp: sp_supra,
            supra_to_reserve: reserve_supra,
            supra_to_target: target_remainder,
        });
    }

    // --- Stability Pool ---

    public entry fun sp_deposit(user: &signer, amt: u64) acquires Registry {
        assert!(amt > 0, E_AMOUNT);
        let u = signer::address_of(user);
        let r = borrow_global_mut<Registry>(@ONE);
        let fa_in = primary_fungible_store::withdraw(user, r.metadata, amt);
        fungible_asset::deposit(r.sp_pool, fa_in);
        if (smart_table::contains(&r.sp_positions, u)) {
            sp_settle(r, u);
            let p = smart_table::borrow_mut(&mut r.sp_positions, u);
            p.initial_balance = p.initial_balance + amt;
        } else {
            smart_table::add(&mut r.sp_positions, u, SP {
                initial_balance: amt,
                snapshot_product: r.product_factor,
                snapshot_index_one: r.reward_index_one,
                snapshot_index_supra: r.reward_index_supra,
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

    // =========================================================
    //                          VIEWS
    // =========================================================

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

    // Returns (effective_balance, pending_one, pending_supra)
    #[view] public fun sp_of(addr: address): (u64, u64, u64) acquires Registry {
        let r = borrow_global<Registry>(@ONE);
        if (smart_table::contains(&r.sp_positions, addr)) {
            let p = smart_table::borrow(&r.sp_positions, addr);
            let eff = ((((p.initial_balance as u256) * (r.product_factor as u256)) / (p.snapshot_product as u256)) as u64);
            let p_one = ((((r.reward_index_one - p.snapshot_index_one) as u256) * (p.initial_balance as u256)) / (p.snapshot_product as u256)) as u64;
            let p_supra = ((((r.reward_index_supra - p.snapshot_index_supra) as u256) * (p.initial_balance as u256)) / (p.snapshot_product as u256)) as u64;
            (eff, p_one, p_supra)
        } else (0, 0, 0)
    }

    #[view] public fun totals(): (u64, u64, u128, u128, u128) acquires Registry {
        let r = borrow_global<Registry>(@ONE);
        (r.total_debt, r.total_sp, r.product_factor, r.reward_index_one, r.reward_index_supra)
    }

    /// SUPRA balance in permanent protocol reserve pool (grows per liquidation at 25% of bonus).
    #[view] public fun reserve_balance(): u64 acquires Registry {
        fungible_asset::balance(borrow_global<Registry>(@ONE).reserve_supra)
    }

    // test_only helpers omitted (stripped from production bytecode):
    //   init_module_for_test, test_create_sp_position, test_route_fee_virtual,
    //   test_create_trove, test_simulate_liquidation
}
```

---

## Context for audit reviewer

- This is a **permissionless** stablecoin with **no governance**. The null-auth pattern means after deploy, nobody can modify the code — not even the deployer. Any bug becomes permanent and users would need to wind down positions manually via `close_trove` (oracle-free path).
- The testnet deployment was smoke-tested end-to-end including bootstrap, SP deposit/withdraw, self-redeem, close_trove, and liquidate(healthy)→E_HEALTHY. Asset conservation verified (~5000 SUPRA in, ~5000 SUPRA out minus ~2% total fees).
- Known acceptable risks (per design):
  - Genesis trove stuck forever (deployer cannot close — missing fee dust)
  - Oracle manipulation window within 1h staleness buffer
  - Supra Foundation framework upgrades could affect oracle/framework dispatch
  - `product_factor` precision decay after ~15+ sequential full-pool liquidations
  - Reserve unreachable except via `redeem_from_reserve` (which requires ONE to burn)

- **Self-audit previously done** in-session (by Claude): 2 rounds, findings fixed:
  - R1: u256 intermediate in sp_settle (overflow prevention), 7 events added, self-heal doc correction
  - R2: `total_sp > debt` strict inequality (prevents product_factor = 0), bootstrap doc hardening

Your external audit is meant to find what a lone in-session Claude would miss.

---

## Unit test coverage (15/15 passing)

- init + view sanity (5 tests)
- Error paths for sp_claim, sp_withdraw, sp_deposit, close_trove (4 tests)
- Reward index math (single + multi-depositor) (2 tests)
- Liquity-P single-depositor liquidation (1 test)
- Liquity-P two-depositor pro-rata absorption (1 test)
- Liquity-P sequential liquidation math (1 test) — verifies P + S updates across multiple liqs
- Warning text on-chain verification (1 test)

Tests use `test_only` helpers (`test_create_sp_position`, `test_route_fee_virtual`, `test_simulate_liquidation`) to bypass external deps (SUPRA FA at 0xa, oracle). Real oracle + real liquidation not tested on chain; mock via helpers.

---

## Questions welcome

Feel free to ask clarifying questions about design intent, deploy procedure, or economic assumptions. Respond in structured audit-report format.
