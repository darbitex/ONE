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
    const STALENESS_MS: u64 = 900_000;                // 15 minutes (R2 5/5 auditor consensus)
    const MAX_FUTURE_DRIFT_MS: u64 = 60_000;          // oracle timestamp future-drift tolerance
    const MIN_DEBT: u64 = 100_000_000;                // 1 ONE (8 dec)
    const PRECISION: u128 = 1_000_000_000_000_000_000;// 1e18 for reward indices + product factor
    const MIN_P_THRESHOLD: u128 = 1_000_000_000;      // Liquity-P cliff guard (1e9 = 1e-9 of original)
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
    const E_PRICE_ZERO: u64 = 11;
    const E_STALE_FUTURE: u64 = 12;
    const E_DECIMAL_OVERFLOW: u64 = 13;
    const E_P_CLIFF: u64 = 14;

    const WARNING: vector<u8> = b"ONE is an immutable stablecoin contract that depends on Supra's native oracle feed. If Supra Foundation ever degrades or misrepresents its oracle, ONE's peg mechanism breaks deterministically - users can wind down via self-close without any external assistance, but new mint/redeem operations become unreliable or frozen. one is immutable = bug is real. Audit this code yourself before interacting. KNOWN LIMITATIONS: (1) Stability Pool enters frozen state when product_factor would drop below 1e9 - protocol aborts further liquidations rather than corrupt SP accounting, accepting bad-debt accumulation past the threshold. (2) Sustained large-scale activity over decades may asymptotically exceed u64 bounds on pending SP rewards. (3) Genesis trove is permanently locked after null-auth - owner cannot self-close. (4) Liquidations of troves with CR below 110 percent absorb as net loss to the SP - the liquidator and the 25 percent reserve share retain their nominal SUPRA amounts, and the SP alone covers the collateral shortfall, deviating from the nominal 25/25/50 split. (5) 25 percent of each fee is burned, creating a structural 0.25 percent aggregate supply-vs-debt gap per cycle (which rises to 1 percent during SP-empty windows because the remaining 75 percent also burns); individual debtors also face a 1 percent per-trove shortfall because only 99 percent is minted while 100 percent is needed to close - full protocol wind-down requires secondary-market ONE for the last debt closure. (6) Self-redemption (redeem against own trove) is allowed and behaves as partial debt repayment plus collateral withdrawal with a 1 percent fee. made by solo dev and claude ai";

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
        assert!(v > 0, E_PRICE_ZERO);
        assert!(ts_ms > 0, E_STALE);
        let now_ms = timestamp::now_seconds() * 1000;
        assert!(ts_ms <= now_ms + MAX_FUTURE_DRIFT_MS, E_STALE_FUTURE);
        assert!(now_ms <= ts_ms + STALENESS_MS, E_STALE);
        let dec = (d as u64);
        if (dec >= 8) v / pow10(dec - 8) else v * pow10(8 - dec)
    }

    fun pow10(n: u64): u128 {
        assert!(n <= 38, E_DECIMAL_OVERFLOW);
        let r: u128 = 1;
        while (n > 0) { r = r * 10; n = n - 1; };
        r
    }

    /// Route fee to SP reward pool (or burn if SP empty). Updates reward_index_one per Liquity-P formula.
    fun route_fee_fa(r: &mut Registry, fa: FungibleAsset) {
        let amt = fungible_asset::amount(&fa);
        if (amt == 0) { fungible_asset::destroy_zero(fa); return };
        // 25% of every fee burned (supply deflation = implicit reserve contribution)
        let burn_amt = (((amt as u128) * 2500) / 10000) as u64;
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
        let fee = (((one_amt as u128) * (FEE_BPS as u128)) / 10000) as u64;
        let net = one_amt - fee;
        let supra_out = (((net as u128) * 100_000_000 / price) as u64);

        let t = smart_table::borrow_mut(&mut r.troves, target);
        assert!(t.debt >= net, E_TARGET);
        assert!(t.collateral >= supra_out, E_COLLATERAL);
        t.debt = t.debt - net;
        t.collateral = t.collateral - supra_out;
        assert!(t.debt == 0 || t.debt >= MIN_DEBT, E_DEBT_MIN);

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
        let fee = (((one_amt as u128) * (FEE_BPS as u128)) / 10000) as u64;
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
    /// Target must have CR < 150%. SP must have total_sp > target.debt (strict).
    /// Bonus (10% of debt) split: 25% to liquidator, 50% to SP depositors, 25% to reserve_supra (all SUPRA).
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

        // Compute seizure amounts (all in USD 8-dec terms, then convert to SUPRA raw).
        // u128 compute → cap against coll (u64 lifted) → cast to u64 last, to avoid
        // pre-cap u64-cast overflow during extreme low-price + large-trove scenarios.
        let bonus_usd = (debt as u128) * (LIQ_BONUS_BPS as u128) / 10000;
        let liq_share_usd = bonus_usd * (LIQ_LIQUIDATOR_BPS as u128) / 10000;
        let reserve_share_usd = bonus_usd * (LIQ_SP_RESERVE_BPS as u128) / 10000;
        let total_seize_usd = (debt as u128) + bonus_usd;
        let total_seize_u128 = total_seize_usd * 100_000_000 / price;
        let coll_u128 = (coll as u128);
        let total_seize_supra = (if (total_seize_u128 > coll_u128) coll_u128 else total_seize_u128) as u64;
        let liq_u128 = liq_share_usd * 100_000_000 / price;
        let total_seize_supra_u128 = (total_seize_supra as u128);
        let liq_supra = (if (liq_u128 > total_seize_supra_u128) total_seize_supra_u128 else liq_u128) as u64;
        let remaining_u128 = total_seize_supra_u128 - (liq_supra as u128);
        let reserve_u128 = reserve_share_usd * 100_000_000 / price;
        let reserve_supra = (if (reserve_u128 > remaining_u128) remaining_u128 else reserve_u128) as u64;
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
        // Cliff guard: abort rather than allow product_factor to collapse past MIN_P_THRESHOLD
        // (would silently wipe SP effective balances in sp_settle via integer truncation).
        let total_before = r.total_sp;
        let new_p = r.product_factor * ((total_before - debt) as u128) / (total_before as u128);
        assert!(new_p >= MIN_P_THRESHOLD, E_P_CLIFF);
        r.reward_index_supra = r.reward_index_supra +
            (sp_supra as u128) * r.product_factor / (total_before as u128);
        r.product_factor = new_p;
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

    // =========================================================
    //             TEST-ONLY HELPERS (stripped from prod)
    // =========================================================

    #[test_only]
    public fun init_module_for_test(deployer: &signer, supra_md: Object<Metadata>) {
        init_module_inner(deployer, supra_md);
    }

    #[test_only]
    public fun test_create_sp_position(addr: address, balance: u64) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        smart_table::add(&mut r.sp_positions, addr, SP {
            initial_balance: balance,
            snapshot_product: r.product_factor,
            snapshot_index_one: r.reward_index_one,
            snapshot_index_supra: r.reward_index_supra,
        });
        r.total_sp = r.total_sp + balance;
    }

    /// Mirrors route_fee_fa's SP share (75% of raw fee amount) for isolated math testing.
    #[test_only]
    public fun test_route_fee_virtual(amount: u64) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        if (r.total_sp == 0) return;
        let sp_amt = amount - amount * 2500 / 10000;  // 75% after 25% burn
        r.reward_index_one = r.reward_index_one + (sp_amt as u128) * r.product_factor / (r.total_sp as u128);
    }

    #[test_only]
    public fun test_create_trove(addr: address, collateral: u64, debt: u64) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        smart_table::add(&mut r.troves, addr, Trove { collateral, debt });
        r.total_debt = r.total_debt + debt;
    }

    /// Direct Liquity-P state update without FA movement or oracle call.
    /// Used for testing the math formula in isolation. Mirrors cliff guard from `liquidate`.
    #[test_only]
    public fun test_simulate_liquidation(debt: u64, sp_supra_absorbed: u64) acquires Registry {
        let r = borrow_global_mut<Registry>(@ONE);
        let total_before = r.total_sp;
        assert!(total_before > debt, E_SP_INSUFFICIENT);
        let new_p = r.product_factor * ((total_before - debt) as u128) / (total_before as u128);
        assert!(new_p >= MIN_P_THRESHOLD, E_P_CLIFF);
        r.reward_index_supra = r.reward_index_supra +
            (sp_supra_absorbed as u128) * r.product_factor / (total_before as u128);
        r.product_factor = new_p;
        r.total_sp = total_before - debt;
    }
}
