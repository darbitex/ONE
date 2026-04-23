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
