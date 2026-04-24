/// ONE — immutable stablecoin on Sui
///
/// WARNING: ONE is an immutable stablecoin contract that depends on
/// Pyth Network's on-chain price feed for SUI/USD. If Pyth degrades or
/// misrepresents its oracle, ONE's peg mechanism breaks deterministically
/// - users can wind down via self-close without any external assistance,
/// but new mint/redeem operations become unreliable or frozen.
/// one is immutable = bug is real. Audit this code yourself before
/// interacting.
module ONE::ONE {
    use std::string;

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::coin_registry;
    use sui::event;
    use sui::package::{Self, UpgradeCap};
    use sui::sui::SUI;
    use sui::table::{Self, Table};

    use pyth::i64;
    use pyth::price;
    use pyth::price_identifier;
    use pyth::price_info::{Self, PriceInfoObject};
    use pyth::pyth;

    // ============================================================
    // Constants
    // ============================================================

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
    const MAX_CONF_BPS: u64 = 200;                    // Pyth confidence cap: 2% of price
    // SUI is 9 decimals (MIST); ONE is 8 decimals. Collateral-value math scales by 1e9.
    const SUI_SCALE: u128 = 1_000_000_000;
    const SUI_USD_PYTH_FEED: vector<u8> = x"23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744";

    // ============================================================
    // Errors
    // ============================================================

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
    const E_WRONG_FEED: u64 = 17;
    const E_SEALED: u64 = 18;
    const E_PRICE_UNCERTAIN: u64 = 19;

    const WARNING: vector<u8> = b"ONE is an immutable stablecoin contract on Sui that depends on Pyth Network's on-chain price feed for SUI/USD. If Pyth degrades or misrepresents its oracle, ONE's peg mechanism breaks deterministically - users can wind down via self-close without any external assistance, but new mint/redeem operations become unreliable or frozen. one is immutable = bug is real. Audit this code yourself before interacting. KNOWN LIMITATIONS: (1) Stability Pool enters frozen state when product_factor would drop below 1e9 - protocol aborts further liquidations rather than corrupt SP accounting, accepting bad-debt accumulation past the threshold. (2) Sustained large-scale activity over decades may asymptotically exceed u64 bounds on pending SP rewards. (3) Liquidation seized collateral is distributed in priority: liquidator bonus first (nominal 2.5 percent of debt value, being 25 percent of the 10 percent liquidation bonus), then 2.5 percent reserve share (also 25 percent of bonus), then SP absorbs the remainder and the debt burn. At CR roughly 110% to 150% the SP alone covers the collateral shortfall. At CR below ~5% the liquidator may take the entire remaining collateral, reserve and SP receive zero, and SP still absorbs the full debt burn. (4) 25 percent of each fee is burned, creating a structural 0.25 percent aggregate supply-vs-debt gap per cycle (which rises to 1 percent during SP-empty windows because the remaining 75 percent also burns); individual debtors also face a 1 percent per-trove shortfall because only 99 percent is minted while 100 percent is needed to close - full protocol wind-down requires secondary-market ONE for the last debt closure. (5) Self-redemption (redeem against own trove) is allowed and behaves as partial debt repayment plus collateral withdrawal with a 1 percent fee. (6) Pyth is pull-based on Sui - callers must refresh the SUI/USD PriceInfoObject via pyth::update_single_price_feed within the same PTB, or oracle-dependent entries abort with E_STALE. (7) Extreme low-price regimes may cause transient aborts in redeem paths when requested amounts exceed u64 output bounds; use smaller amounts and retry. (8) ORACLE UPGRADE RISK (Sui-specific): Pyth Sui (pkg 0x04e20ddf..., state 0x1f931023...) is NOT cryptographically immutable. Its UpgradeCap sits inside shared State with policy=0 (compatible), controlled by Pyth DAO via Wormhole VAA governance. Sui's compatibility checker prevents public-function signature regressions, but does NOT prevent feed-id deregistration, Price struct field reshuffling, or Wormhole state rotation - any of which could brick this consumer. No admin escape once this package is sealed. Accept as external-dependency risk. Oracle-free escape hatches remain fully open: close_trove lets any trove owner reclaim their collateral by burning the full trove debt in ONE (acquiring the 1 percent close deficit via secondary market if needed); add_collateral lets owners top up existing troves without touching the oracle; sp_deposit, sp_withdraw, and sp_claim let SP depositors manage and exit their positions and claim any rewards accumulated before the freeze. Protocol-owned SUI held in reserve_coll becomes permanently locked because redeem_from_reserve requires the oracle. No admin override exists; the freeze is final. (9) REDEMPTION vs LIQUIDATION are two separate mechanisms. liquidate is health-gated (requires CR below 150 percent) and applies a penalty bonus to the liquidator, the reserve, and the SP; healthy troves cannot be liquidated by anyone. redeem has no health gate on target and executes a value-neutral swap at oracle spot price - the target's debt decreases by net ONE while their collateral decreases by net times 1e9 over price SUI (Sui native is 9 decimals), so the target retains full value at spot. Redemption is the protocol peg-anchor: when ONE trades below 1 USD on secondary market, any holder can burn ONE supply by redeeming for SUI, pushing the peg back up. The target is caller-specified; there is no sorted-by-CR priority, unlike Liquity V1's sorted list - the economic result for the target is identical to Liquity (made whole at spot), only the redemption ordering differs, and ordering is a peg-efficiency optimization rather than a safety property. Borrowers who want guaranteed long-term SUI exposure without the possibility of redemption-induced position conversion should not use ONE troves - use a non-CDP lending protocol instead. Losing optionality under redemption is not the same as losing value: the target is economically indifferent at spot.";

    // ============================================================
    // One-time witness
    // ============================================================

    public struct ONE has drop {}

    // ============================================================
    // State types
    // ============================================================

    public struct Trove has store, drop { collateral: u64, debt: u64 }

    public struct SP has store, drop {
        initial_balance: u64,
        snapshot_product: u128,
        snapshot_index_one: u128,
        snapshot_index_coll: u128,
    }

    /// Single-use capability proving origin (publisher). Consumed by destroy_cap.
    public struct OriginCap has key { id: UID }

    /// Shared protocol state. Owns TreasuryCap and every pooled balance.
    public struct Registry has key {
        id: UID,
        treasury: TreasuryCap<ONE>,
        fee_pool: Balance<ONE>,
        sp_pool: Balance<ONE>,
        sp_coll_pool: Balance<SUI>,
        reserve_coll: Balance<SUI>,
        treasury_coll: Balance<SUI>,
        troves: Table<address, Trove>,
        sp_positions: Table<address, SP>,
        total_debt: u64,
        total_sp: u64,
        product_factor: u128,
        reward_index_one: u128,
        reward_index_coll: u128,
        sealed: bool,
    }

    // ============================================================
    // Events
    // ============================================================

    public struct TroveOpened has copy, drop { user: address, new_collateral: u64, new_debt: u64, added_debt: u64 }
    public struct CollateralAdded has copy, drop { user: address, amount: u64 }
    public struct TroveClosed has copy, drop { user: address, collateral: u64, debt: u64 }
    public struct Redeemed has copy, drop { user: address, target: address, one_amt: u64, coll_out: u64 }
    public struct Liquidated has copy, drop {
        liquidator: address, target: address, debt: u64,
        coll_to_liquidator: u64, coll_to_sp: u64,
        coll_to_reserve: u64, coll_to_target: u64,
    }
    public struct SPDeposited has copy, drop { user: address, amount: u64 }
    public struct SPWithdrew has copy, drop { user: address, amount: u64 }
    public struct SPClaimed has copy, drop { user: address, one_amt: u64, coll_amt: u64 }
    public struct ReserveRedeemed has copy, drop { user: address, one_amt: u64, coll_out: u64 }
    public struct FeeBurned has copy, drop { amount: u64 }
    public struct CapDestroyed has copy, drop { caller: address, timestamp_ms: u64 }
    public struct RewardSaturated has copy, drop { user: address, pending_one_truncated: bool, pending_coll_truncated: bool }

    // ============================================================
    // Init
    // ============================================================

    fun init(witness: ONE, ctx: &mut TxContext) {
        // Register via CoinRegistry (Sui framework >= 1.48) so the coin is
        // indexable by wallets/explorers that query the global registry.
        // finalize_and_delete_metadata_cap consumes MetadataCap, making the
        // metadata (name/symbol/decimals/description/icon_url) permanently
        // immutable. Currency<ONE> is transferred as a Receiving to the
        // CoinRegistry address; a separate `coin_registry::finalize_registration`
        // call (anyone can invoke — bundled into deploy-scripts) promotes it
        // to a shared object keyed by the ONE type.
        let (initializer, treasury) = coin_registry::new_currency_with_otw<ONE>(
            witness,
            8,
            string::utf8(b"ONE"),
            string::utf8(b"1"),
            string::utf8(b"Immutable CDP-backed stablecoin on Sui (SUI-collateralized)"),
            string::utf8(b""),
            ctx,
        );
        coin_registry::finalize_and_delete_metadata_cap(initializer, ctx);
        let reg = Registry {
            id: object::new(ctx),
            treasury,
            fee_pool: balance::zero<ONE>(),
            sp_pool: balance::zero<ONE>(),
            sp_coll_pool: balance::zero<SUI>(),
            reserve_coll: balance::zero<SUI>(),
            treasury_coll: balance::zero<SUI>(),
            troves: table::new<address, Trove>(ctx),
            sp_positions: table::new<address, SP>(ctx),
            total_debt: 0,
            total_sp: 0,
            product_factor: PRECISION,
            reward_index_one: 0,
            reward_index_coll: 0,
            sealed: false,
        };
        transfer::share_object(reg);
        transfer::transfer(OriginCap { id: object::new(ctx) }, tx_context::sender(ctx));
    }

    // ============================================================
    // Sealing (one-shot, irreversible)
    // ============================================================

    /// Consumes OriginCap + UpgradeCap in a single call. Package becomes
    /// cryptographically immutable via sui::package::make_immutable, and
    /// `sealed` flips true. No admin surface remains.
    public fun destroy_cap(
        origin: OriginCap,
        reg: &mut Registry,
        upgrade: UpgradeCap,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(!reg.sealed, E_SEALED);
        let OriginCap { id } = origin;
        object::delete(id);
        package::make_immutable(upgrade);
        reg.sealed = true;
        event::emit(CapDestroyed {
            caller: tx_context::sender(ctx),
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ============================================================
    // Oracle helpers (internal)
    // ============================================================

    fun now_secs(clock: &Clock): u64 { clock::timestamp_ms(clock) / 1000 }

    fun price_8dec(pi: &PriceInfoObject, clock: &Clock): u128 {
        let info = price_info::get_price_info_from_price_info_object(pi);
        let id = price_info::get_price_identifier(&info);
        assert!(price_identifier::get_bytes(&id) == SUI_USD_PYTH_FEED, E_WRONG_FEED);

        let p = pyth::get_price_no_older_than(pi, clock, STALENESS_SECS);
        let p_i64 = price::get_price(&p);
        let e_i64 = price::get_expo(&p);
        let ts = price::get_timestamp(&p);
        let conf = price::get_conf(&p);
        let now = now_secs(clock);
        assert!(ts + STALENESS_SECS >= now, E_STALE);
        assert!(ts <= now + 10, E_STALE);
        assert!(i64::get_is_negative(&e_i64), E_PRICE_EXPO);
        let abs_e = i64::get_magnitude_if_negative(&e_i64);
        assert!(abs_e <= 18, E_EXPO_BOUND);
        assert!(!i64::get_is_negative(&p_i64), E_PRICE_NEG);
        let raw = (i64::get_magnitude_if_positive(&p_i64) as u128);
        assert!(raw > 0, E_PRICE_ZERO);
        // Reject prices with wide confidence interval — Pyth signals uncertainty via conf.
        // Cap conf/raw ratio at MAX_CONF_BPS (2% default); conf shares price's expo.
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
        let mut r: u128 = 1;
        let mut k = n;
        while (k > 0) { r = r * 10; k = k - 1; };
        r
    }

    // ============================================================
    // Fee routing (internal)
    // ============================================================

    fun route_fee(r: &mut Registry, mut fee_bal: Balance<ONE>, ctx: &mut TxContext) {
        let amt = balance::value(&fee_bal);
        if (amt == 0) { balance::destroy_zero(fee_bal); return };
        let burn_amt = (((amt as u128) * 2500) / 10000) as u64;
        if (burn_amt > 0) {
            let burn_portion = balance::split(&mut fee_bal, burn_amt);
            coin::burn(&mut r.treasury, coin::from_balance(burn_portion, ctx));
            event::emit(FeeBurned { amount: burn_amt });
        };
        let sp_amt = balance::value(&fee_bal);
        if (sp_amt == 0) { balance::destroy_zero(fee_bal); return };
        if (r.total_sp == 0) {
            coin::burn(&mut r.treasury, coin::from_balance(fee_bal, ctx));
        } else {
            balance::join(&mut r.fee_pool, fee_bal);
            r.reward_index_one = r.reward_index_one + (sp_amt as u128) * r.product_factor / (r.total_sp as u128);
        }
    }

    // ============================================================
    // SP settle (internal)
    // ============================================================

    fun sp_settle(r: &mut Registry, u: address, ctx: &mut TxContext) {
        let (snap_p, snap_i_one, snap_i_coll, initial) = {
            let pos = table::borrow(&r.sp_positions, u);
            (pos.snapshot_product, pos.snapshot_index_one, pos.snapshot_index_coll, pos.initial_balance)
        };
        if (snap_p == 0 || initial == 0) {
            let pos = table::borrow_mut(&mut r.sp_positions, u);
            pos.snapshot_product = r.product_factor;
            pos.snapshot_index_one = r.reward_index_one;
            pos.snapshot_index_coll = r.reward_index_coll;
            return
        };

        let u64_max: u256 = 18446744073709551615;
        let raw_one = ((r.reward_index_one - snap_i_one) as u256) * (initial as u256) / (snap_p as u256);
        let raw_coll = ((r.reward_index_coll - snap_i_coll) as u256) * (initial as u256) / (snap_p as u256);
        let raw_bal = (initial as u256) * (r.product_factor as u256) / (snap_p as u256);
        // Saturate at u64::MAX rather than abort — prevents permanent SP position lock
        // if decades of fee accrual push pending rewards past u64 bounds.
        let one_trunc = raw_one > u64_max;
        let coll_trunc = raw_coll > u64_max;
        let pending_one = (if (one_trunc) u64_max else raw_one) as u64;
        let pending_coll = (if (coll_trunc) u64_max else raw_coll) as u64;
        let new_balance = (if (raw_bal > u64_max) u64_max else raw_bal) as u64;
        if (one_trunc || coll_trunc) {
            event::emit(RewardSaturated { user: u, pending_one_truncated: one_trunc, pending_coll_truncated: coll_trunc });
        };

        {
            let pos = table::borrow_mut(&mut r.sp_positions, u);
            pos.initial_balance = new_balance;
            pos.snapshot_product = r.product_factor;
            pos.snapshot_index_one = r.reward_index_one;
            pos.snapshot_index_coll = r.reward_index_coll;
        };

        if (pending_one > 0) {
            let c = coin::from_balance(balance::split(&mut r.fee_pool, pending_one), ctx);
            transfer::public_transfer(c, u);
        };
        if (pending_coll > 0) {
            let c = coin::from_balance(balance::split(&mut r.sp_coll_pool, pending_coll), ctx);
            transfer::public_transfer(c, u);
        };
        if (pending_one > 0 || pending_coll > 0) {
            event::emit(SPClaimed { user: u, one_amt: pending_one, coll_amt: pending_coll });
        }
    }

    // ============================================================
    // Trove operations — public (PTB-composable)
    // ============================================================

    /// Opens or adds to a trove. Returns freshly minted ONE (net of 1% fee).
    public fun open_trove(
        reg: &mut Registry,
        coll: Coin<SUI>,
        debt: u64,
        pi: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<ONE> {
        assert!(debt >= MIN_DEBT, E_DEBT_MIN);
        let user_addr = tx_context::sender(ctx);
        let coll_amt = coin::value(&coll);
        let price = price_8dec(pi, clock);

        let is_existing = table::contains(&reg.troves, user_addr);
        let (prior_coll, prior_debt) = if (is_existing) {
            let t = table::borrow(&reg.troves, user_addr);
            (t.collateral, t.debt)
        } else (0, 0);
        let new_coll = prior_coll + coll_amt;
        let new_debt = prior_debt + debt;
        let coll_usd = (new_coll as u128) * price / SUI_SCALE;
        assert!(coll_usd * 10000 >= MCR_BPS * (new_debt as u128), E_COLLATERAL);

        balance::join(&mut reg.treasury_coll, coin::into_balance(coll));
        let fee = (((debt as u128) * (FEE_BPS as u128)) / 10000) as u64;
        let user_coin = coin::mint(&mut reg.treasury, debt - fee, ctx);
        let fee_coin = coin::mint(&mut reg.treasury, fee, ctx);
        route_fee(reg, coin::into_balance(fee_coin), ctx);

        if (is_existing) {
            let t = table::borrow_mut(&mut reg.troves, user_addr);
            t.collateral = new_coll;
            t.debt = new_debt;
        } else {
            table::add(&mut reg.troves, user_addr, Trove { collateral: new_coll, debt: new_debt });
        };
        reg.total_debt = reg.total_debt + debt;
        event::emit(TroveOpened { user: user_addr, new_collateral: new_coll, new_debt, added_debt: debt });
        user_coin
    }

    /// Top up existing trove with extra collateral. No oracle needed.
    public fun add_collateral(
        reg: &mut Registry,
        coll: Coin<SUI>,
        ctx: &mut TxContext,
    ) {
        let user_addr = tx_context::sender(ctx);
        let amt = coin::value(&coll);
        assert!(amt > 0, E_AMOUNT);
        assert!(table::contains(&reg.troves, user_addr), E_TROVE);
        balance::join(&mut reg.treasury_coll, coin::into_balance(coll));
        let t = table::borrow_mut(&mut reg.troves, user_addr);
        t.collateral = t.collateral + amt;
        event::emit(CollateralAdded { user: user_addr, amount: amt });
    }

    /// Close owner's trove by burning `debt` ONE. Any excess ONE is returned to sender.
    /// Returns the trove's collateral as a fresh Coin<SUI>.
    public fun close_trove(
        reg: &mut Registry,
        one_in: Coin<ONE>,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        let user_addr = tx_context::sender(ctx);
        assert!(table::contains(&reg.troves, user_addr), E_TROVE);
        let t = table::remove(&mut reg.troves, user_addr);
        let Trove { collateral, debt } = t;
        let mut one_in_mut = one_in;
        if (debt > 0) {
            assert!(coin::value(&one_in_mut) >= debt, E_AMOUNT);
            let burn_coin = coin::split(&mut one_in_mut, debt, ctx);
            coin::burn(&mut reg.treasury, burn_coin);
        };
        let excess = coin::value(&one_in_mut);
        if (excess > 0) {
            transfer::public_transfer(one_in_mut, user_addr);
        } else {
            coin::destroy_zero(one_in_mut);
        };
        reg.total_debt = reg.total_debt - debt;
        event::emit(TroveClosed { user: user_addr, collateral, debt });
        coin::from_balance(balance::split(&mut reg.treasury_coll, collateral), ctx)
    }

    /// Redeem ONE against a specific target trove. Value-neutral at spot.
    public fun redeem(
        reg: &mut Registry,
        one_in: Coin<ONE>,
        target: address,
        pi: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        let user_addr = tx_context::sender(ctx);
        let one_amt = coin::value(&one_in);
        assert!(one_amt >= MIN_DEBT, E_AMOUNT);
        assert!(table::contains(&reg.troves, target), E_TARGET);
        let price = price_8dec(pi, clock);
        let fee = (((one_amt as u128) * (FEE_BPS as u128)) / 10000) as u64;
        let net = one_amt - fee;
        let coll_out = (((net as u128) * SUI_SCALE / price) as u64);

        let t = table::borrow_mut(&mut reg.troves, target);
        assert!(t.debt >= net, E_TARGET);
        assert!(t.collateral >= coll_out, E_COLLATERAL);
        t.debt = t.debt - net;
        t.collateral = t.collateral - coll_out;
        assert!(t.debt == 0 || t.debt >= MIN_DEBT, E_DEBT_MIN);
        assert!(t.debt == 0 || t.collateral > 0, E_COLLATERAL);

        let mut one_in_mut = one_in;
        let fee_coin = coin::split(&mut one_in_mut, fee, ctx);
        coin::burn(&mut reg.treasury, one_in_mut);       // burns `net`
        route_fee(reg, coin::into_balance(fee_coin), ctx);
        reg.total_debt = reg.total_debt - net;
        event::emit(Redeemed { user: user_addr, target, one_amt, coll_out });
        coin::from_balance(balance::split(&mut reg.treasury_coll, coll_out), ctx)
    }

    /// Redeem ONE against protocol-owned reserve_coll. No trove targeted.
    /// Note: burns circulating ONE without decrementing total_debt, widening
    /// the supply-vs-debt gap — this is intentional (reserve-drain mechanic).
    public fun redeem_from_reserve(
        reg: &mut Registry,
        one_in: Coin<ONE>,
        pi: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        let user_addr = tx_context::sender(ctx);
        let one_amt = coin::value(&one_in);
        assert!(one_amt >= MIN_DEBT, E_AMOUNT);
        let price = price_8dec(pi, clock);
        let fee = (((one_amt as u128) * (FEE_BPS as u128)) / 10000) as u64;
        let net = one_amt - fee;
        let coll_out = (((net as u128) * SUI_SCALE / price) as u64);
        assert!(balance::value(&reg.reserve_coll) >= coll_out, E_INSUFFICIENT_RESERVE);

        let mut one_in_mut = one_in;
        let fee_coin = coin::split(&mut one_in_mut, fee, ctx);
        coin::burn(&mut reg.treasury, one_in_mut);
        route_fee(reg, coin::into_balance(fee_coin), ctx);

        let out = coin::from_balance(balance::split(&mut reg.reserve_coll, coll_out), ctx);
        event::emit(ReserveRedeemed { user: user_addr, one_amt, coll_out });
        out
    }

    /// Liquidate an unhealthy trove. Returns the liquidator's SUI bonus.
    /// Reserve share goes to reserve_coll; SP remainder to sp_coll_pool;
    /// any coll left over (after total seize) returned directly to target.
    public fun liquidate(
        reg: &mut Registry,
        target: address,
        pi: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        assert!(table::contains(&reg.troves, target), E_TARGET);
        let price = price_8dec(pi, clock);
        let (debt, coll) = {
            let t_ref = table::borrow(&reg.troves, target);
            (t_ref.debt, t_ref.collateral)
        };
        let coll_usd = (coll as u128) * price / SUI_SCALE;

        assert!(coll_usd * 10000 < LIQ_THRESHOLD_BPS * (debt as u128), E_HEALTHY);
        assert!(reg.total_sp > debt, E_SP_INSUFFICIENT);

        let total_before = reg.total_sp;
        let new_p = reg.product_factor * ((total_before - debt) as u128) / (total_before as u128);
        assert!(new_p >= MIN_P_THRESHOLD, E_P_CLIFF);

        let bonus_usd = (debt as u128) * (LIQ_BONUS_BPS as u128) / 10000;
        let liq_share_usd = bonus_usd * (LIQ_LIQUIDATOR_BPS as u128) / 10000;
        let reserve_share_usd = bonus_usd * (LIQ_SP_RESERVE_BPS as u128) / 10000;
        let total_seize_usd = (debt as u128) + bonus_usd;
        let total_seize_u128 = total_seize_usd * SUI_SCALE / price;
        let coll_u128 = (coll as u128);
        let total_seize_coll = (if (total_seize_u128 > coll_u128) coll_u128 else total_seize_u128) as u64;
        let liq_u128 = liq_share_usd * SUI_SCALE / price;
        let total_seize_coll_u128 = (total_seize_coll as u128);
        let liq_coll = (if (liq_u128 > total_seize_coll_u128) total_seize_coll_u128 else liq_u128) as u64;
        let remaining_u128 = total_seize_coll_u128 - (liq_coll as u128);
        let reserve_u128 = reserve_share_usd * SUI_SCALE / price;
        let reserve_coll_amt = (if (reserve_u128 > remaining_u128) remaining_u128 else reserve_u128) as u64;
        let sp_coll = total_seize_coll - liq_coll - reserve_coll_amt;
        let target_remainder = coll - total_seize_coll;

        let _ = table::remove(&mut reg.troves, target);
        reg.total_debt = reg.total_debt - debt;

        // Burn SP-owned ONE equal to the wiped debt
        let burn_bal = balance::split(&mut reg.sp_pool, debt);
        coin::burn(&mut reg.treasury, coin::from_balance(burn_bal, ctx));

        reg.reward_index_coll = reg.reward_index_coll +
            (sp_coll as u128) * reg.product_factor / (total_before as u128);
        reg.product_factor = new_p;
        reg.total_sp = total_before - debt;

        // Split seized collateral: reserve → reserve_coll, SP → sp_coll_pool, liquidator → return
        let mut seized = balance::split(&mut reg.treasury_coll, total_seize_coll);
        if (reserve_coll_amt > 0) {
            balance::join(&mut reg.reserve_coll, balance::split(&mut seized, reserve_coll_amt));
        };
        if (sp_coll > 0) {
            balance::join(&mut reg.sp_coll_pool, balance::split(&mut seized, sp_coll));
        };
        if (target_remainder > 0) {
            let rem = coin::from_balance(balance::split(&mut reg.treasury_coll, target_remainder), ctx);
            transfer::public_transfer(rem, target);
        };

        let liquidator = tx_context::sender(ctx);
        event::emit(Liquidated {
            liquidator, target, debt,
            coll_to_liquidator: liq_coll,
            coll_to_sp: sp_coll,
            coll_to_reserve: reserve_coll_amt,
            coll_to_target: target_remainder,
        });
        coin::from_balance(seized, ctx)
    }

    // ============================================================
    // Stability Pool — public entries
    // ============================================================

    public fun sp_deposit(
        reg: &mut Registry,
        one_in: Coin<ONE>,
        ctx: &mut TxContext,
    ) {
        let amt = coin::value(&one_in);
        assert!(amt > 0, E_AMOUNT);
        let u = tx_context::sender(ctx);
        balance::join(&mut reg.sp_pool, coin::into_balance(one_in));
        // Reset-on-empty: when the pool has been fully drained (previous cliff-freeze
        // plus all prior depositors withdrew), reset product_factor to full precision
        // so liquidations can resume. No active depositor is harmed — there are none.
        if (reg.total_sp == 0) {
            reg.product_factor = PRECISION;
        };
        if (table::contains(&reg.sp_positions, u)) {
            sp_settle(reg, u, ctx);
            let p = table::borrow_mut(&mut reg.sp_positions, u);
            p.initial_balance = p.initial_balance + amt;
        } else {
            table::add(&mut reg.sp_positions, u, SP {
                initial_balance: amt,
                snapshot_product: reg.product_factor,
                snapshot_index_one: reg.reward_index_one,
                snapshot_index_coll: reg.reward_index_coll,
            });
        };
        reg.total_sp = reg.total_sp + amt;
        event::emit(SPDeposited { user: u, amount: amt });
    }

    public fun sp_withdraw(
        reg: &mut Registry,
        amt: u64,
        ctx: &mut TxContext,
    ): Coin<ONE> {
        assert!(amt > 0, E_AMOUNT);
        let u = tx_context::sender(ctx);
        assert!(table::contains(&reg.sp_positions, u), E_SP_BAL);
        sp_settle(reg, u, ctx);
        let empty = {
            let pos = table::borrow_mut(&mut reg.sp_positions, u);
            assert!(pos.initial_balance >= amt, E_SP_BAL);
            pos.initial_balance = pos.initial_balance - amt;
            pos.initial_balance == 0
        };
        reg.total_sp = reg.total_sp - amt;
        let out = coin::from_balance(balance::split(&mut reg.sp_pool, amt), ctx);
        if (empty) { let _ = table::remove(&mut reg.sp_positions, u); };
        event::emit(SPWithdrew { user: u, amount: amt });
        out
    }

    public fun sp_claim(reg: &mut Registry, ctx: &mut TxContext) {
        let u = tx_context::sender(ctx);
        assert!(table::contains(&reg.sp_positions, u), E_SP_BAL);
        sp_settle(reg, u, ctx);
    }

    // ============================================================
    // PTB-friendly entry wrappers (transfer-to-sender)
    // ============================================================

    public fun open_trove_entry(
        reg: &mut Registry,
        coll: Coin<SUI>,
        debt: u64,
        pi: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let c = open_trove(reg, coll, debt, pi, clock, ctx);
        transfer::public_transfer(c, tx_context::sender(ctx));
    }

    public fun close_trove_entry(
        reg: &mut Registry,
        one_in: Coin<ONE>,
        ctx: &mut TxContext,
    ) {
        let c = close_trove(reg, one_in, ctx);
        transfer::public_transfer(c, tx_context::sender(ctx));
    }

    public fun redeem_entry(
        reg: &mut Registry,
        one_in: Coin<ONE>,
        target: address,
        pi: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let c = redeem(reg, one_in, target, pi, clock, ctx);
        transfer::public_transfer(c, tx_context::sender(ctx));
    }

    public fun redeem_from_reserve_entry(
        reg: &mut Registry,
        one_in: Coin<ONE>,
        pi: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let c = redeem_from_reserve(reg, one_in, pi, clock, ctx);
        transfer::public_transfer(c, tx_context::sender(ctx));
    }

    public fun liquidate_entry(
        reg: &mut Registry,
        target: address,
        pi: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let c = liquidate(reg, target, pi, clock, ctx);
        transfer::public_transfer(c, tx_context::sender(ctx));
    }

    public fun sp_withdraw_entry(
        reg: &mut Registry,
        amt: u64,
        ctx: &mut TxContext,
    ) {
        let c = sp_withdraw(reg, amt, ctx);
        transfer::public_transfer(c, tx_context::sender(ctx));
    }

    // ============================================================
    // Views
    // ============================================================

    public fun read_warning(): vector<u8> { WARNING }

    public fun price_view(pi: &PriceInfoObject, clock: &Clock): u128 {
        price_8dec(pi, clock)
    }

    public fun trove_of(reg: &Registry, addr: address): (u64, u64) {
        if (table::contains(&reg.troves, addr)) {
            let t = table::borrow(&reg.troves, addr);
            (t.collateral, t.debt)
        } else (0, 0)
    }

    public fun sp_of(reg: &Registry, addr: address): (u64, u64, u64) {
        if (table::contains(&reg.sp_positions, addr)) {
            let p = table::borrow(&reg.sp_positions, addr);
            let eff = ((((p.initial_balance as u256) * (reg.product_factor as u256)) / (p.snapshot_product as u256)) as u64);
            let p_one = ((((reg.reward_index_one - p.snapshot_index_one) as u256) * (p.initial_balance as u256)) / (p.snapshot_product as u256)) as u64;
            let p_coll = ((((reg.reward_index_coll - p.snapshot_index_coll) as u256) * (p.initial_balance as u256)) / (p.snapshot_product as u256)) as u64;
            (eff, p_one, p_coll)
        } else (0, 0, 0)
    }

    public fun totals(reg: &Registry): (u64, u64, u128, u128, u128) {
        (reg.total_debt, reg.total_sp, reg.product_factor, reg.reward_index_one, reg.reward_index_coll)
    }

    public fun reserve_balance(reg: &Registry): u64 {
        balance::value(&reg.reserve_coll)
    }

    public fun is_sealed(reg: &Registry): bool { reg.sealed }

    /// Exact ONE amount user needs to burn to close_trove. Useful for UIs
    /// to display the 1 percent secondary-market deficit.
    public fun close_cost(reg: &Registry, addr: address): u64 {
        if (table::contains(&reg.troves, addr)) {
            table::borrow(&reg.troves, addr).debt
        } else 0
    }

    /// Returns (collateral, debt, cr_bps). cr_bps = 0 if no trove or trove has zero debt.
    /// Oracle-dependent — shares price_8dec's abort semantics.
    public fun trove_health(
        reg: &Registry,
        addr: address,
        pi: &PriceInfoObject,
        clock: &Clock,
    ): (u64, u64, u64) {
        if (!table::contains(&reg.troves, addr)) return (0, 0, 0);
        let t = table::borrow(&reg.troves, addr);
        if (t.debt == 0) return (t.collateral, 0, 0);
        let price = price_8dec(pi, clock);
        let coll_usd = (t.collateral as u128) * price / SUI_SCALE;
        let cr_bps = (coll_usd * 10000 / (t.debt as u128)) as u64;
        (t.collateral, t.debt, cr_bps)
    }

    // ============================================================
    // Test-only helpers (mirrors Aptos test surface)
    // ============================================================

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ONE {}, ctx);
    }

    #[test_only]
    public fun test_create_sp_position(reg: &mut Registry, addr: address, balance: u64) {
        table::add(&mut reg.sp_positions, addr, SP {
            initial_balance: balance,
            snapshot_product: reg.product_factor,
            snapshot_index_one: reg.reward_index_one,
            snapshot_index_coll: reg.reward_index_coll,
        });
        reg.total_sp = reg.total_sp + balance;
    }

    #[test_only]
    public fun test_route_fee_virtual(reg: &mut Registry, amount: u64) {
        if (reg.total_sp == 0) return;
        let sp_amt = amount - amount * 2500 / 10000;
        reg.reward_index_one = reg.reward_index_one + (sp_amt as u128) * reg.product_factor / (reg.total_sp as u128);
    }

    #[test_only]
    public fun test_create_trove(reg: &mut Registry, addr: address, collateral: u64, debt: u64) {
        table::add(&mut reg.troves, addr, Trove { collateral, debt });
        reg.total_debt = reg.total_debt + debt;
    }

    #[test_only]
    public fun test_simulate_liquidation(reg: &mut Registry, debt: u64, sp_coll_absorbed: u64) {
        let total_before = reg.total_sp;
        assert!(total_before > debt, E_SP_INSUFFICIENT);
        let new_p = reg.product_factor * ((total_before - debt) as u128) / (total_before as u128);
        assert!(new_p >= MIN_P_THRESHOLD, E_P_CLIFF);
        reg.reward_index_coll = reg.reward_index_coll +
            (sp_coll_absorbed as u128) * reg.product_factor / (total_before as u128);
        reg.product_factor = new_p;
        reg.total_sp = total_before - debt;
    }

    #[test_only]
    public fun test_set_sp_position(
        reg: &mut Registry, addr: address, initial: u64, snap_p: u128, snap_i_one: u128, snap_i_coll: u128
    ) {
        if (table::contains(&reg.sp_positions, addr)) {
            let p = table::borrow_mut(&mut reg.sp_positions, addr);
            p.initial_balance = initial;
            p.snapshot_product = snap_p;
            p.snapshot_index_one = snap_i_one;
            p.snapshot_index_coll = snap_i_coll;
        } else {
            table::add(&mut reg.sp_positions, addr, SP {
                initial_balance: initial,
                snapshot_product: snap_p,
                snapshot_index_one: snap_i_one,
                snapshot_index_coll: snap_i_coll,
            });
        };
    }

    #[test_only]
    public fun test_get_sp_snapshots(reg: &Registry, addr: address): (u64, u128, u128, u128) {
        let p = table::borrow(&reg.sp_positions, addr);
        (p.initial_balance, p.snapshot_product, p.snapshot_index_one, p.snapshot_index_coll)
    }

    #[test_only]
    public fun test_force_reward_indices(reg: &mut Registry, one_idx: u128, coll_idx: u128) {
        reg.reward_index_one = one_idx;
        reg.reward_index_coll = coll_idx;
    }

    #[test_only]
    public fun test_call_sp_settle(reg: &mut Registry, addr: address, ctx: &mut TxContext) {
        sp_settle(reg, addr, ctx);
    }

    #[test_only]
    public fun test_mint_origin_cap(ctx: &mut TxContext): OriginCap {
        OriginCap { id: object::new(ctx) }
    }

    #[test_only]
    public fun test_seal_without_upgrade_cap(
        origin: OriginCap, reg: &mut Registry, clock: &Clock, ctx: &mut TxContext
    ) {
        assert!(!reg.sealed, E_SEALED);
        let OriginCap { id } = origin;
        object::delete(id);
        reg.sealed = true;
        event::emit(CapDestroyed {
            caller: tx_context::sender(ctx),
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }
}
