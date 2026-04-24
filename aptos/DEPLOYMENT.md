# ONE — Aptos Mainnet Deployment Record

Version: **v0.1.3** — LIVE + SEALED (immutable)
Deploy date: 2026-04-24

## Addresses

| | |
|---|---|
| Package | `0x85ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab87387` |
| ONE FA metadata | `0xee5ebaf6ff851955cccaa946f9339bab7f7407d72c6673b029576747ba3fadc4` |
| Origin (deployer) | `0x0047a3e13465172e10661e20b7b618235e9c7e62a365d315e91cf1ef647321c9` |
| Pyth package | `0x7e783b349d3e89cf5931af376ebeadbfab855b3fa239b7ada8f5a92fbea6b387` (auth_key = 0x0, cryptographically immutable) |
| Pyth APT/USD feed id | `0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5` |

Resource-account derivation: seed = `ONE` (utf8), origin = `0x0047a3e1...`.

## Immutability

ResourceCap consumed on 2026-04-24 via `destroy_cap(origin=0x0047)` tx `0x529f06db...2954fbb`. `is_sealed()` view returns `true`. No actor — including the original deployer — can reconstruct a signer for the ONE package address. Code is permanently frozen.

## Genesis trove

| | |
|---|---|
| Owner | `0x0047a3e1...` |
| Collateral | 2.2 APT (220_000_000 raw) |
| Debt | 1 ONE (100_000_000 raw) |
| MCR at open | 205.28% (APT = $0.9331) |
| Deployer ONE balance | 0.99 (99_000_000 raw) — 1 ONE mint minus 1% fee burned (SP was empty, so entire fee was burned) |

## Deploy transactions (in order)

1. **Publish** — `0xf087e928dbf8cf4232cb054bc07138efc4c5d4b796368ef96204f6feaecf3126`
   - Resource account created + package published
   - Gas: 169_717 units × 100 octas = 0.17 APT
2. **Pyth VAA update** — `0x745d1d647b5fea85710c2743c6d1e5c88b95f19c1b1be08a8c671c0185803d71`
   - Fresh APT/USD VAA pushed on-chain before trove open
3. **open_trove** — `0x0765295f15f29285311812c38a80053a74ae2303fd0cca6b4e061d920cd0725d`
   - Bootstrap: 2.2 APT locked, 1 ONE minted (0.99 to deployer + 0.01 fee burned)
4. **destroy_cap** — `0x529f06dbd5d21ff361e96993545c70a07fb35893024f23155f9daef6b2954fbb`
   - ResourceCap consumed. Package permanently sealed. Gas: 56 units (0.0000056 APT).

## Verification views (call anytime via Aptos REST `/v1/view`)

```
0x85ee9c43...::ONE::is_sealed()            -> true
0x85ee9c43...::ONE::totals()               -> (total_debt, total_sp, product_factor, reward_index_one, reward_index_coll)
0x85ee9c43...::ONE::trove_of(addr)         -> (collateral, debt)
0x85ee9c43...::ONE::sp_of(addr)            -> (effective_balance, pending_one, pending_coll)
0x85ee9c43...::ONE::reserve_balance()      -> u64
0x85ee9c43...::ONE::price()                -> u128 (APT/USD, 8-decimal, aborts if Pyth stale)
0x85ee9c43...::ONE::read_warning()         -> vector<u8> (on-chain WARNING const)
0x85ee9c43...::ONE::metadata_addr()        -> address (ONE FA metadata)
0x85ee9c43...::ONE::close_cost(addr)       -> u64 (ONE amount needed to close a trove)
0x85ee9c43...::ONE::trove_health(addr)     -> (collateral, debt, cr_bps)
```

## Audit history

- **R1** (2026-04-23): 8 fresh auditors. 15 findings, all fixed → v0.1.1.
- **R2** (2026-04-23): Claude fresh. 1 CRITICAL (sp_settle phantom reward) + 1 MEDIUM (redeem coll=0 grief) + 1 LOW (WARNING liquidator share mislabel). All fixed → v0.1.2.
- **R3** (2026-04-23): Gemini 3.1. Raised NEW-C01 (arbitrary redemption target) as CRITICAL.
- **R3.1** (2026-04-24): Added WARNING (9) disclosure → Gemini 3.1 reclassified NEW-C01 as INFO / design accepted. Claude fresh: GREEN. Both confirmed v0.1.3.

Full audit trail in `audit/` subdir.

## User parameters (locked at deploy)

- MIN_DEBT = 1 ONE ($1 retail-accessible)
- MCR open = 200% (borrower must be ≥2× overcollateralized at open)
- LIQ threshold = 150% (liquidatable below)
- FEE = 1% flat on mint + 1% flat on redeem (25% burn / 75% SP)
- STALENESS_SECS = 60 (Pyth freshness)
- MAX_CONF_BPS = 200 (Pyth confidence ≤ 2% of price)
- MIN_P_THRESHOLD = 1e9 (SP cliff guard)

## Philosophy

ONE is built for retail — not whales. Immutable, single collateral (APT), single oracle (Pyth), zero interest, flat fees, no governance token, no admin, no upgrades. If Pyth APT/USD feed ever goes dormant, the oracle-dependent entries (open_trove, redeem, liquidate) freeze but oracle-free escape hatches (close_trove, add_collateral, sp_*) remain open forever.

---

## R4 post-mainnet disclosures

Five external R4 auditors reviewed the deployed bytecode (SHA-256 `5f197f105440deba82f3419e912e40a461a7cca368d520988e27f7d88f94d92a`) after 2026-04-24. Verdict: **GREEN with 1 MEDIUM disclosure gap and several LOW / INFO items**. No CRITICAL, no HIGH. Contract is sealed — the following items are disclosure-only; no in-place patch is possible.

Full audit record: `audit/AUDIT_R4_POST_MAINNET.md`. Per-auditor responses verbatim: `audit/AUDIT_R4_TRACKING.md`.

### Immutability verification walkthrough (R4-I-01)

External reviewers should verify the 3-layer defense in the following order. Passing **any one** layer is not sufficient — only the combination guarantees cryptographic immutability.

1. **Policy layer** (`upgrade_policy`): `PackageRegistry.packages[0].upgrade_policy = 1` ("compatible"). This is **NOT** a safety property — it only means *future* upgrades must be backward-compatible, assuming someone has a signer. It does not prevent upgrades.

2. **Auth layer** (`authentication_key`): `curl https://fullnode.mainnet.aptoslabs.com/v1/accounts/0x85ee9c43…` returns `authentication_key = 0x00…00` (32 zero bytes). Resource accounts have no private-key signer by construction; only a derived `SignerCapability` can act for them.

3. **Capability layer** (`ResourceCap`): `curl https://fullnode.mainnet.aptoslabs.com/v1/accounts/0x85ee9c43…/resources` lists only `Registry`, `0x1::account::Account`, `0x1::code::PackageRegistry`. **No `ResourceCap` resource exists.** This was consumed by the `destroy_cap` tx (`0x529f06dbd5d21ff361e96993545c70a07fb35893024f23155f9daef6b2954fbb`).

With layers 2 + 3, no actor — including the original deployer — can derive a signer for `@ONE`. The package code is permanently frozen. Same check applied to the Pyth dep at `0x7e78…b387` also confirms `auth_key = 0x00…00`.

### Oracle-lag redemption disclosure (R4-M-01)

**The only MEDIUM-severity finding in R4.** Not a peg-break, not a protocol fund-loss; it's a wealth transfer vector against trove owners.

**Mechanism**: Pyth is pull-based. The on-chain cached price (`P_stored`) can lag market price (`P_market`) by up to 60 seconds (`STALENESS_SECS`). Anyone can call the **bare** `redeem(one_amt, target)` entry — **NOT** `redeem_pyth` — which uses `P_stored` without refreshing Pyth. If `P_market > P_stored` by more than 1%, the caller extracts `(Δ − 1%) × net` of APT value from the target trove per call.

**Economics at current state**: genesis trove 5.10 ONE debt. At a 2% oracle-lag (common in minute-scale APT moves), a full-drain redemption extracts ~0.10 ONE-worth of excess APT from the genesis owner. The 1% fee is the designed absorption band; above that is pure extraction.

**Why MEDIUM and not HIGH**: 1% fee cushion matches Liquity V1's Chainlink-lag behavior. Target retains value at oracle spot; market-vs-oracle divergence is bounded by the 60s window. Trove owner can preemptively refresh Pyth themselves via `pyth::update_price_feeds_with_funder` (costs only Pyth update fee + gas).

**Why MEDIUM and not LOW**: bootstrap phase = low volume = low third-party Pyth refresh cadence = 60s window routinely used. Single-trove concentration = all extraction lands on one owner.

**User-facing reworded clause (9)**: *"value-neutral at **oracle-recorded** spot price (which may lag market spot by up to 60 seconds)"*. The on-chain WARNING cannot be edited; this disclosure lives in docs and the frontend.

**Trove-owner defenses**:
1. Call `pyth::update_price_feeds_with_funder` standalone before expected volatility — makes `P_stored` fresh for the next ~60s window.
2. Monitor APT/USD off-chain and pre-close trove if you expect a large adverse move.
3. Use a keeper bot to auto-refresh Pyth on your behalf.

### Operational risks at bootstrap (R4-D-01)

**All 5 R4 auditors flagged this.** Severity classifications ranged DESIGN / LOW / MEDIUM / INFO across auditors (Qwen's CRIT misclassification rejected). The operational concern is unanimous.

**Current state** (as of 2026-04-24): `total_sp = 0` and one trove (genesis: 11.08 APT / 5.10 ONE / CR 202.63%). `liquidate` requires `total_sp > debt` strictly. With SP at zero, **no trove is liquidatable at any CR**.

**Trigger threshold**: if APT/USD drops ~26% (to ~$0.69 from the deploy price of $0.9328), the genesis trove crosses `LIQ_THRESHOLD_BPS` (150% CR) and becomes "health-unhealthy" but not on-chain-liquidatable. Protocol enters bad-debt accumulation with no recovery mechanism until SP is seeded.

**DOS amplification** (Kimi's extension): an adversarial party could `sp_deposit(exactly debt)` to keep `total_sp == debt` — the strict `>` check still aborts every liquidate call. Attacker loses nothing economically (their SP deposit is not liquidated because liquidate aborts), but consumes capital without profit. Self-limiting: any honest actor with ≥ `debt + 1` of fresh capital defeats it by alone satisfying the inequality.

**First-liquidator capital cost** (Claude's extension): to bootstrap liquidation of the genesis trove, the first liquidator needs:
- ~10.2 APT to open their own trove at MCR = 200% minting ≥ 5.10 ONE,
- 99% of minted ONE lands in their wallet (SP-empty full-burn path on fee routing, so fees don't return as SP rewards either),
- ~0.10 ONE shortfall acquired from the Darbitex USDC/ONE pool at `0x630a4cb9debd41de85be38195cd6f9825f9f309ced29c15c6a4c4a438ba19675`,
- Total capital: ~$10.10 at current APT price to capture a bonus of 2.5% × 5.10 ONE = $0.13.

At current scale, first-liquidation is capital-intensive relative to the bonus. Economic rationality kicks in only when APT crashes enough to produce a liquidatable trove AND the bonus exceeds capital costs.

**Preemption options available to the genesis owner**:
- `add_collateral` — push CR back above 150% (no oracle check required).
- Self-redeem — shrink debt via `redeem(net, own_address)` (1% fee).
- Acquire ONE + `close_trove` — requires ~5.05 ONE from the secondary market (5.10 debt - 0.049 already in wallet + rounding buffer) + the close tx.
- `sp_deposit` own ONE (if held) — but deployer only holds 0.049 ONE; would need to acquire from Darbitex pool first.

**Operator action** (decision deferred to owner): seed SP with a nominal amount (e.g., 1-2 ONE) once secondary-market ONE is available. Closes the DOS amplification window and enables eventual permissionless liquidations.

### Known documentation / UX notes (R4)

1. **WARNING (3) text imprecision** (R4-L-01): on-chain text says "CR ~5%" for both SP-zero and reserve-zero boundaries. Actual: SP-zero at CR ≈ 5%; reserve-zero at CR ≈ 2.5%. Code behavior is correct; the constant is slightly over-pessimistic.

2. **MIN_DEBT trove redemption fragmentation** (R4-L-02): a trove at exactly 1 ONE debt (MIN_DEBT) cannot be cleanly redeemed with any `one_amt ∈ [100_000_000, 101_010_100]` — all abort `E_DEBT_MIN` because residual debt falls into `(0, MIN_DEBT)`. Exact clearing amount is `one_amt = 101_010_101` (= `100_000_000 × 100/99` rounded). Frontend must compute and display this.

3. **MIN_P_THRESHOLD cliff can block liquidation** (R4-L-03): after many prior liquidations push `product_factor` near the 1e9 floor, a narrow `total_sp > debt` margin can still fail the `new_p >= MIN_P_THRESHOLD` check. Not reachable in bootstrap state (pf = 1e18) but becomes relevant in mature state.

4. **`total_debt` semantics** (R4-L-04): `totals()[0]` = sum of live trove debts, **not** circulating ONE supply. After any `redeem_from_reserve` call, circulating supply decreases but `total_debt` is intentionally unchanged (source comment at line 389-392 documents this). Integrators must read circulating supply from `fungible_asset::supply(metadata)` if they need it; do not use `total_debt` as a supply proxy. The divergence is the intended reserve-drain peg-pressure mechanic.

5. **`sp_of` view aborts where `sp_settle` saturates** (R4-I-02): asymptotic WARNING (2) territory — pending rewards exceeding u64::MAX. Frontend should catch and fall back. User funds always recoverable via `sp_claim`/`sp_withdraw`.

6. **MIN_DEBT applies per call, not per trove** (R4-I-03): users wanting sub-1-ONE debt increments cannot use `open_trove` alone (each call must add ≥ 1 ONE of debt). Use `add_collateral` for pure collateral top-up.

7. **Asymptotic u128 bounds** (R4-I-04 + R4-I-05): `coll_usd × 10000` in MCR/LIQ checks, and `reward_index_coll` accumulator, both have asymptotic u128 overflow bounds that require implausible magnitudes (>> all APT supply at >> $1e18/coin, or billions of extreme liquidations). Not reachable in realistic operation; arithmetic-overflow abort would freeze the path rather than corrupt state.

8. **Zero-debt residual trove** (R4-I-06): after a full self-redeem or external redeem that zeroes a trove's debt, the trove row persists with `coll > 0, debt = 0`. Cannot be re-redeemed (blocked at debt >= net check) or liquidated (CR*0 = 0 fails the strict-less check). Owner must call `close_trove` to reclaim the collateral (no ONE cost; burn branch skipped).

9. **No partial delever function** (R4-I-07): the module has no `withdraw_collateral_partial` or `repay_debt_partial` entry. Users wanting partial deleverage must self-redeem (1% fee + MIN_DEBT gate) or close + reopen.

10. **Pyth confidence check is instantaneous** (R4-I-08): the 2% conf-over-price gate at line 186 evaluates publication-time confidence. A narrow-confidence price that then stales for 60 seconds passes the check unchanged. The 60s `STALENESS_SECS` bound is the sole time-lag defense; combined with R4-M-01, this is why the pull-oracle extraction vector exists.

11. **SP state bloat via `initial_balance → 0`** (R4-I-09): if a user's SP deposit was small (e.g., < 1 ONE) and subsequent liquidations pushed `product_factor` near the cliff, the saturated `new_balance` can round to 0 via u64 truncation. The position row persists permanently in `sp_positions` but cannot be removed (sp_withdraw requires `amt > 0`). Sub-realistic in practice; trivial storage cost.

### Recommended monitoring (off-chain)

External tools / integrators should monitor the following on-chain derived signals:

- **Pyth freshness**: `now - Pyth.ts_stored` — if approaching 60s and APT is volatile, trove owners should refresh preemptively.
- **Supply-vs-debt gap**: `fungible_asset::supply(metadata) vs totals()[0]` — the gap widens after every redeem_from_reserve + cumulative fee burn. An aggregated gap > ~5% warrants user attention (approaching "last closer pays higher secondary premium" dynamics).
- **SP occupancy vs largest trove**: `total_sp` vs the largest live trove's `debt` — if SP < debt of the largest trove, that trove is un-liquidatable even if unhealthy.
- **Product_factor headroom**: `product_factor / MIN_P_THRESHOLD` — once this approaches 1, liquidation paths become increasingly fragile (R4-L-03 cliff).
- **Active trove count + CR distribution**: for peg-risk dashboarding.
