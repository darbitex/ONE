# ONE Stablecoin — Round 1 Audit Submission

**Version:** v0.1.0
**Target chain:** Aptos mainnet
**Language:** Move 2
**Philosophy:** Purist immutable, no governance, no admin, no upgrade after `destroy_cap`
**Oracle:** Pyth Network on-chain feed (APT/USD, pull-based VAA updates)
**Warning embedded on-chain:** "one is immutable = bug is real."

---

## Audit request

You are auditing a Move-language stablecoin named ONE on Aptos. The protocol is permissionless and designed to be immutable post-deploy. Once the `destroy_cap` entry function is called by the origin, no signer can be reconstructed for the package account — any bug that survives this audit is permanent.

Review as if real user funds are at stake. Focus on:

### 1. Math correctness

- **Liquity-P stability pool mechanism**: `product_factor` + dual `reward_index` (ONE fees + APT from liquidations). Verify formula conservation across deposit / withdraw / liquidation / fee sequences. Check precision-decay behavior under sequential liquidations.
- **Fee split**: 1% mint + 1% redeem fees. Of the fee: 25% burned (supply deflation), 75% distributed to SP via `reward_index_one`.
- **Liquidation split 25/50/25**: 25% of bonus to liquidator (APT), 50% of bonus to SP depositors (APT via `reward_index_coll`), 25% of bonus accumulates permanently in `reserve_coll`.
- **Debt + bonus extraction**: `total_seize_usd = debt_usd + bonus_usd`, converted via oracle price, capped at target collateral. Downstream splits must not underflow or assign more collateral than exists.
- **Overflow**: particular attention in `sp_settle` (`delta × balance / snap_p`), `reward_index` updates (`amount × P / total_sp`), and u128-to-u64 casts in `liquidate` and `redeem*` paths.

### 2. Oracle integration (`price_8dec()`)

- `pyth::get_price_no_older_than(id, STALENESS_SECS)` aborts when Pyth's cached price is older than 15 minutes. Is the pull-based pattern correctly assumed? Callers are expected to submit a VAA update via `pyth::update_price_feeds_with_funder` before any oracle-dependent entry.
- Expo validation: we assert the Pyth expo is negative (standard for USD feeds). Price must be strictly positive. Post-scaling, we re-assert the scaled result is non-zero (defensive vs ultra-low raw × high-magnitude expo combinations).
- Staleness belt-and-suspenders: we re-check `ts + STALENESS_SECS >= now` and `ts <= now + 5s` using `price::get_timestamp` and our own `aptos_framework::timestamp`.
- What if Pyth misbehaves mid-tx? What if the APT/USD feed is ever de-registered?

### 3. Resource-account immutability (`ResourceCap` + `destroy_cap`)

- Package is published at a resource account via `resource_account::create_resource_account_and_publish_package` (origin + seed). `init_module` retrieves the resulting `SignerCapability` via `retrieve_resource_account_cap(resource, @origin)` and stores it in a `ResourceCap` resource at `@ONE`.
- `destroy_cap` is gated to `@origin` and `move_from`s the `ResourceCap`, letting the inner `SignerCapability` (which has `drop`) go out of scope. Double-call protected via `exists<ResourceCap>(@ONE)`.
- Between publish and `destroy_cap`, can any actor reconstruct a signer for `@ONE`? Specifically: can origin extract the cap via any path other than `destroy_cap`? Can a malicious module installed by origin read the stored cap? Can the resource account itself sign anything given that its `auth_key` is auto-rotated to `0x0` by the resource-account framework during publish?
- `@origin` is hardcoded via Move.toml named address. Is there a risk that if origin is compromised between publish and destroy, attacker can do anything more than call `destroy_cap` (which drops the cap without releasing control)?

### 4. Reentrancy + FA dispatch surface

- Move VM's resource model + exclusive `&mut` borrows prevent classic reentrancy. Verify no dynamic dispatch paths introduce a window.
- ONE's own FA is created via `create_primary_store_enabled_fungible_asset` with no dispatch hooks. Confirm.
- APT FA at `@0xa` (managed by `aptos_framework::aptos_coin`). Does any known or future dispatch hook on APT FA allow re-entering ONE::ONE during `primary_fungible_store::withdraw` or `::deposit`?

### 5. Supply invariants

- `open_trove`: supply += (debt - burned_portion_of_fee); total_debt += debt.
- `redeem`: supply -= (net + burned_portion_of_fee); target.debt -= net; total_debt -= net.
- `redeem_from_reserve`: supply -= (net + burned_portion_of_fee); no trove changes. Does this correctly NOT touch `total_debt` (since `total_debt = Σ t.debt` is trove-level, not supply)?
- `liquidate`: supply -= debt (burned from sp_pool); target.debt removed; total_debt -= debt.
- `close_trove`: supply -= t.debt; target trove removed; total_debt -= t.debt.
- Cross-check: at all times, `total_debt = Σ t.debt over all troves` (no drift). Circulating supply can be less than total_debt by the cumulative burned amount (intentional deflation).

### 6. Edge cases

- `sp_settle` when `initial_balance = 0` or `snapshot_product = 0` (early return).
- `sp_withdraw` dropping `initial_balance` to zero → `smart_table::remove`.
- `product_factor` approaching precision floor: `MIN_P_THRESHOLD = 1e9` guard aborts liquidations that would push P below. Accepts bad-debt accumulation as explicit design.
- `redeem_from_reserve` when `reserve_coll` balance is insufficient — hard assertion, no partial fills.
- Multiple `liquidate` in same block against same target — second hits `smart_table::contains` = false → `E_TARGET`.
- `open_trove` with `coll_amt = 0` against existing trove — allowed by design (debt-only top-up). Should this be explicit-reject?
- `close_trove` when user wallet ONE balance < `t.debt` — aborts inside `primary_fungible_store::withdraw`.
- Redemption against target that leaves dust debt: post-redeem assertion `t.debt == 0 || t.debt >= MIN_DEBT` prevents un-closeable dust troves. Is the zero-debt branch safe (trove stays registered, owner can still `close_trove` to burn 0 ONE + reclaim collateral)?
- Pyth returns `price_i64` with negative magnitude: our `E_PRICE_NEG` catches this.
- Pyth returns expo with positive sign: our `E_PRICE_EXPO` catches this.
- Pyth returns raw `0`: our `E_PRICE_ZERO` catches this.
- Post-scaling result `0` (extreme high-magnitude expo + low raw): our second `E_PRICE_ZERO` check catches.

### 7. Deploy + immutability safety

- Publish: `create_resource_account_and_publish_package(origin_signer, seed, metadata, code)` creates resource account, rotates its auth_key to 0x0, stores SignerCapability at origin, publishes package. `init_module` runs.
- `destroy_cap` runs as a second tx. Window between publish and destroy_cap: origin has cap accessible via `retrieve_resource_account_cap`, but our `init_module` already consumed it. Can origin re-retrieve? (Presumably no — once consumed, the cap's entry in `ResourceAccountCaps` is removed.)
- After `destroy_cap`: no actor can sign for `@ONE`. `upgrade_policy = "compatible"` has no effect because no signer exists.

### 8. Immutable constants

All hardcoded forever. Any that should be parameterized?

```
MCR_BPS             = 20000  // 200%
LIQ_THRESHOLD_BPS   = 15000  // 150%
LIQ_BONUS_BPS       = 1000   // 10% of debt
LIQ_LIQUIDATOR_BPS  = 2500   // 25% of bonus
LIQ_SP_DEPOSITOR_BPS = 5000  // 50% of bonus
LIQ_SP_RESERVE_BPS  = 2500   // 25% of bonus
FEE_BPS             = 100    // 1% mint/redeem
STALENESS_SECS      = 900    // 15 minutes
MIN_DEBT            = 100_000_000  // 1 ONE
PRECISION           = 1e18
MIN_P_THRESHOLD     = 1e9
APT_FA              = @0xa
APT_USD_PYTH_FEED   = 0x03ae4d... (32-byte id)
```

### 9. Test coverage gaps

Review `tests/ONE_tests.move` (19 tests, 19 pass). Any critical invariant or edge case that lacks a test? In particular, oracle-dependent paths (open_trove, redeem, liquidate, redeem_from_reserve) are NOT exercised by the unit tests — they're tested at integration level on testnet/mainnet separately.

### 10. What to produce

A structured report per finding:

- **Severity**: CRITICAL / HIGH / MEDIUM / LOW / INFO / NIT
- **Location**: `sources/ONE.move:LINE` or function name
- **Issue**: what's wrong or suspect
- **Impact**: practical failure mode
- **Recommendation**: specific fix
- **Confidence**: your certainty level

At the end, provide overall verdict: **PROCEED TO PUBLISH / NEEDS FIX BATCH / NOT READY**.

---

## Protocol spec

### Identity
- Name: ONE
- Ticker: 1
- Decimals: 8
- Peg target: $1 USD (via Pyth APT/USD feed)

### Collateral
- APT on Aptos (FA at `@0xa`, 8 decimals)

### Economic parameters (locked at deploy)
```
Open MCR             : 200%
Liquidation threshold: 150%
Liquidation bonus    : 10% of debt, split 25/50/25 (liq/SP/reserve)
Mint fee             : 1% of debt, 25% burn, 75% SP (burn if SP empty)
Redeem fee           : 1% of one_amt, same split as mint
Min debt per trove   : 1 ONE
Oracle staleness     : 15 min (Pyth + own check)
SP absorption        : Liquity-P
Post-redeem invariant: t.debt == 0 OR t.debt >= MIN_DEBT
SP cliff guard       : MIN_P_THRESHOLD = 1e9 (abort liq rather than corrupt)
```

### Entry functions
```
open_trove(user, coll_amt, debt)          — deposit APT FA, mint ONE
add_collateral(user, coll_amt)            — top up without minting
close_trove(user)                          — burn debt, unlock all collateral (oracle-free)
redeem(user, one_amt, target)             — burn ONE for oracle-priced APT from target
redeem_from_reserve(user, one_amt)        — burn ONE for APT from protocol reserve
liquidate(liquidator, target)             — absorb underwater trove (CR < 150%)
sp_deposit(user, amt)                      — lock ONE in SP for yield
sp_withdraw(user, amt)                     — exit SP (settles pending first)
sp_claim(user)                             — claim pending rewards only
destroy_cap(origin)                        — one-time post-publish; consume+drop SignerCapability
```

### View functions
```
read_warning() → vector<u8>                — on-chain warning text
metadata_addr() → address                  — ONE FA metadata addr
price() → u128                              — APT/USD at 8 decimals (Pyth-backed)
trove_of(addr) → (u64, u64)                — (collateral, debt)
sp_of(addr) → (u64, u64, u64)              — (balance, pending_one, pending_coll)
totals() → (u64, u64, u128, u128, u128)    — (total_debt, total_sp, P, r_one, r_coll)
reserve_balance() → u64                     — APT in permanent reserve pool
```

### On-chain warning text

The full WARNING is stored as a `vector<u8>` const and readable via `read_warning()`. It enumerates seven known limitations:

1. SP frozen state when `product_factor` would drop below 1e9 (cliff guard accepts bad-debt accumulation)
2. Asymptotic u64 overflow on pending SP rewards under sustained activity over decades
3. Liquidations of troves with CR below 110% impose net loss on SP (asymmetric split under collateral shortfall)
4. 25% fee burn creates ~0.25% supply-vs-debt gap per cycle (rises to 1% in SP-empty windows); individual debtors face 1% per-trove shortfall requiring secondary-market ONE for full wind-down
5. Self-redemption allowed; behaves as partial repay + collateral withdraw + 1% fee
6. Pyth pull-based: callers must ensure fresh price via VAA update before oracle-dependent entries
7. Extreme low-price regimes may cause transient aborts on redeem paths when requested amounts exceed u64 output bounds

---

## Test suite

19/19 pass. Compile + test:
```bash
aptos move test --named-addresses ONE=<any-address>
```

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

Oracle paths (open_trove, redeem, liquidate, redeem_from_reserve) are NOT covered by unit tests (Pyth is not mockable in Move test VM without substantial framework work). They are exercised via integration testing on live chain.

---

## External references

Pyth on Aptos mainnet:
- Package: `0x7e783b349d3e89cf5931af376ebeadbfab855b3fa239b7ada8f5a92fbea6b387` (immutable, auth_key = `0x0`)
- APT/USD feed id: `0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5`
- VAA source: https://hermes.pyth.network/

Target resource address (deterministic, from origin `0x0047a3e1...` + seed `"ONE"`): `0x6a202785cf0a1d5c682e952056f5b55dae8b0616617b46f55f452ce31b1035e8`.

---

## Full source

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

### deps/pyth/sources/ (local Pyth interface stub)

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
}

module pyth::price {
    use pyth::i64::I64;
    struct Price has copy, drop, store { price: I64, conf: u64, expo: I64, timestamp: u64 }
    public fun new(_p: I64, _c: u64, _e: I64, _t: u64): Price { abort 0 }
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

The stub bodies all `abort 0` — at runtime, the real Pyth module at `pyth = 0x7e78...` is called; the stub only provides type resolution at compile time.

### sources/ONE.move (full)

[Full 570-line source submitted separately as attachment / paste. Key sections below for inline reference:]

**Price reader with defence-in-depth:**

```move
fun price_8dec(): u128 {
    let id = price_identifier::from_byte_vec(APT_USD_PYTH_FEED);
    let p: Price = pyth::get_price_no_older_than(id, STALENESS_SECS);
    let p_i64 = price::get_price(&p);
    let e_i64 = price::get_expo(&p);
    let ts = price::get_timestamp(&p);
    let now = timestamp::now_seconds();
    assert!(ts + STALENESS_SECS >= now, E_STALE);
    assert!(ts <= now + 5, E_STALE);
    assert!(i64::get_is_negative(&e_i64), E_PRICE_EXPO);
    let abs_e = i64::get_magnitude_if_negative(&e_i64);
    assert!(!i64::get_is_negative(&p_i64), E_PRICE_NEG);
    let raw = (i64::get_magnitude_if_positive(&p_i64) as u128);
    assert!(raw > 0, E_PRICE_ZERO);
    let result = if (abs_e >= 8) {
        raw / pow10(abs_e - 8)
    } else {
        raw * pow10(8 - abs_e)
    };
    assert!(result > 0, E_PRICE_ZERO);
    result
}
```

**Resource-account immutability:**

```move
fun init_module(resource: &signer) {
    let cap = resource_account::retrieve_resource_account_cap(resource, @origin);
    move_to(resource, ResourceCap { cap: option::some(cap) });
    init_module_inner(resource, object::address_to_object<Metadata>(APT_FA));
}

public entry fun destroy_cap(caller: &signer) acquires ResourceCap {
    assert!(signer::address_of(caller) == @origin, E_NOT_ORIGIN);
    assert!(exists<ResourceCap>(@ONE), E_CAP_GONE);
    let ResourceCap { cap } = move_from<ResourceCap>(@ONE);
    let _sc = option::destroy_some(cap);
}
```

**Liquidation with cliff guard:**

```move
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

    // ... seizure distribution + state updates + FA movements
}
```

**Everything else** (route_fee_fa, sp_settle, open_impl, close_impl, redeem_impl, sp_deposit, sp_withdraw, sp_claim, views, Registry layout, events, error codes 1-18) is provided in full in the separate source paste.
