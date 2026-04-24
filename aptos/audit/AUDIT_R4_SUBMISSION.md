# ONE Aptos — R4 Post-Mainnet Audit Submission

**Context.** ONE is a retail-first, immutable, APT-collateralized stablecoin on Aptos mainnet. It is **already deployed and cryptographically sealed**: no actor — including the original deployer — can upgrade, pause, or modify the package. This audit round (R4) is a post-mainnet adversarial review of the actual deployed bytecode. Findings cannot be patched in-place; they translate into external user disclosures, frontend warnings, and (in extremis) migration plans. We explicitly want auditors to attack assuming the contract is frozen and user funds are already in it.

This submission is self-contained: it includes the full source, the full on-chain bytecode as a hex dump, the manifest, instructions to reproduce the bytecode-parity check, the prior audit verdict trail, and our own internal R4 self-audit findings (for you to disprove, extend, or escalate).

---

## 1. Deployment identity

| | |
|---|---|
| **Package address** | `0x85ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab87387` |
| **Module** | `0x85ee9c43…aab87387::ONE` |
| **ONE FA metadata** | `0xee5ebaf6ff851955cccaa946f9339bab7f7407d72c6673b029576747ba3fadc4` (8-decimal fungible asset, symbol `1`, name `ONE`) |
| **Resource-account origin (deployer)** | `0x0047a3e13465172e10661e20b7b618235e9c7e62a365d315e91cf1ef647321c9` |
| **Pyth dependency package** | `0x7e783b349d3e89cf5931af376ebeadbfab855b3fa239b7ada8f5a92fbea6b387` (auth_key = 0x0, cryptographically immutable) |
| **APT/USD Pyth price feed id** | `0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5` |
| **APT FA metadata** | `@0xa` (framework-canonical Aptos Coin migration FA) |
| **Deploy date** | 2026-04-24 |
| **Source version** | v0.1.3 (`Move.toml` `version = "0.1.3"`) |

### Deployment transactions (mainnet)

1. **Publish** — `0xf087e928dbf8cf4232cb054bc07138efc4c5d4b796368ef96204f6feaecf3126`
2. **Pyth VAA update** — `0x745d1d647b5fea85710c2743c6d1e5c88b95f19c1b1be08a8c671c0185803d71`
3. **`open_trove` (genesis)** — `0x0765295f15f29285311812c38a80053a74ae2303fd0cca6b4e061d920cd0725d`  (2.2 APT / 1 ONE mint)
4. **`destroy_cap` (seal)** — `0x529f06dbd5d21ff361e96993545c70a07fb35893024f23155f9daef6b2954fbb`

### Post-deploy state at submission time

```
is_sealed()          = true
totals()             = (total_debt=510000000, total_sp=0, product_factor=1e18, reward_index_one=0, reward_index_coll=0)
reserve_balance()    = 0
metadata_addr()      = 0xee5ebaf6ff851955cccaa946f9339bab7f7407d72c6673b029576747ba3fadc4
trove_of(0x0047)     = (collateral=1108000000, debt=510000000)    // 11.08 APT / 5.10 ONE
close_cost(0x0047)   = 510000000                                  // = trove.debt
```

(Genesis trove was augmented post-deploy to 11.08 APT / 5.10 ONE debt. SP was empty for both mints, so the full 1% fee on each mint was burned rather than routed to SP.)

---

## 2. Immutability — three-layer defense

All three of the following are independently verifiable on chain. The weakest one breaks the guarantee.

1. **Policy layer.** `PackageRegistry.packages[0].upgrade_policy = 1` (compatible). *By itself this does NOT prevent upgrades.* Shown for completeness — the real guarantees come from layers 2 and 3.

2. **Authentication layer.** `authentication_key` of the package account `0x85ee9c43…` is `0x00…00` (32 zero bytes). Resource accounts never had a private-key-derivable signer to begin with; the framework sets `auth_key=0x0` for them. No private key exists and none can be derived. Verifiable with:
   ```
   curl -s https://fullnode.mainnet.aptoslabs.com/v1/accounts/0x85ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab87387
   → {"sequence_number":"0","authentication_key":"0x00…00"}
   ```

3. **Capability layer.** At publish, `init_module` retrieved the `SignerCapability` for the resource account and stashed it in a `ResourceCap` resource under `@ONE`. The origin then consumed it via the `destroy_cap` entry (tx 4 above), which `move_from`s and `destroy_some`s the `Option<SignerCapability>`. The resource no longer exists on-chain. Verifiable with:
   ```
   curl -s https://fullnode.mainnet.aptoslabs.com/v1/accounts/0x85ee9c43…/resources
   → resources listed: Registry, 0x1::account::Account, 0x1::code::PackageRegistry. No ResourceCap.
   ```

Same layer-2 check applied to the Pyth dependency at `0x7e78…b387` — `auth_key=0x00…00` — confirms our oracle's host package is equally immutable. See `WARNING (8)` in the on-chain text for the residual oracle-freeze risk (feed rotation / permanent unavailability — not an upgrade vector).

---

## 3. Reproducible bytecode-parity proof

The source below compiles byte-identical to the on-chain bytecode. Any auditor can verify this themselves:

```
# 1. Clone source
git clone https://github.com/darbitex/ONE
cd ONE/aptos

# 2. Compile with the deployed address as the named-address for `ONE`
aptos move compile \
    --skip-fetch-latest-git-deps \
    --named-addresses ONE=0x85ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab87387

# 3. Pull the on-chain module bytecode
curl -s "https://fullnode.mainnet.aptoslabs.com/v1/accounts/0x85ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab87387/modules?limit=10" \
    | python3 -c 'import json,sys,binascii; d=json.load(sys.stdin); open("onchain.mv","wb").write(binascii.unhexlify(d[0]["bytecode"][2:]))'

# 4. Compare
sha256sum build/ONE/bytecode_modules/ONE.mv onchain.mv
# Both should print: 5f197f105440deba82f3419e912e40a461a7cca368d520988e27f7d88f94d92a
```

**This audit was performed against bytecode whose SHA-256 is `5f197f105440deba82f3419e912e40a461a7cca368d520988e27f7d88f94d92a` (14173 bytes).**

If your local compile produces a different hash, either (a) your tooling version differs from ours, or (b) the source has been tampered with after publication. Either way stop and tell us before proceeding.

Toolchain used for reproducibility check: `aptos 9.1.0`, AptosFramework pinned to `rev = "mainnet"` as of 2026-04-24.

---

## 4. What we want from R4 auditors

**Scope.** The entire surface of the sealed module `ONE::ONE`, with the post-deployment context above. Non-goals: architecture/design proposals (cannot be applied), code restructuring (irrelevant), ergonomic recommendations (nice to have). We want attacks.

**Focus areas we consider high-return for R4:**

1. **Economic attacks under the exact current post-mainnet state.** `total_sp=0`, single genesis trove at 11.08 APT / 5.10 ONE, reserve empty, ~5 ONE in a Darbitex USDC/ONE pool at `0x630a4cb9debd41de85be38195cd6f9825f9f309ced29c15c6a4c4a438ba19675` (constant-product AMM, 1:1 seeded). Is there a profitable attack given these exact balances?

2. **Peg-break paths.** Any sequence of entries (including via `*_pyth` wrappers with attacker-controlled fresh VAAs) that can drive the ONE/USDC rate on Darbitex permanently away from 1:1 beyond redemption's natural repair.

3. **Permanent state corruption** of `product_factor`, `reward_index_one`, `reward_index_coll`, `total_sp`, or `total_debt` — anything that makes a view return nonsensical numbers or future operations revert permanently.

4. **Capability or signer leakage.** We believe `@ONE`'s signer is unreachable post-`destroy_cap` (layer 3). Disprove this.

5. **Reentrancy** via a fungible-asset dispatch hook. Our belief: ONE is created non-dispatchable (no hook), and APT has `EAPT_NOT_DISPATCHABLE`. Disprove by producing a concrete path.

6. **Oracle manipulation** beyond what `WARNING (8)` already covers. The Pyth VAA submitted by a `*_pyth` caller must pass guardian signatures, so we don't consider forged VAAs in scope — but consider timing games around the 60-second staleness window and the `ts <= now + 10` future-tolerance check.

7. **Integer overflow / truncation** at realistic magnitudes (not the asymptotic u128 bound noted in § 7 below).

8. **Liquidation DOS / grief.** Can a trove be made un-closeable or un-liquidatable permanently while remaining a solvency drag?

9. **Redemption target-selection abuse.** WARNING (9) discloses that targets are caller-specified and documents value-neutrality at spot. Can the caller extract *more than* value-neutral by any path?

10. **Bootstrap-specific attacks.** With the genesis trove as the only trove, any game-theory angle around being the first/only counterparty.

**Severity rubric.**
- CRITICAL: direct user-fund loss, peg break >>1%, protocol state unrecoverable with on-chain tools.
- HIGH: user-fund loss under realistic market conditions, severe griefing, multi-operation inconsistency with economic impact.
- MEDIUM: limited griefing, DX/observability gaps that can cause users to transact on wrong info, escapable oracle/parameter edge cases.
- LOW: documentation errors inside on-chain text (like the WARNING const), minor precision issues, confusing view returns.
- INFO: observations, asymptotic bounds, style.

**Response format we prefer.** Matching AUDIT_TRACKING.md style:
```
[SEVERITY] <location>: <one-line>
<concrete attack or scenario, including assumed pre-state>
<impact on users / protocol>
<whether this can be mitigated off-chain (frontend/disclosure) given the contract is sealed>
```

---

## 5. Prior audit history (summary — for context, not as a filter)

R4 auditors should feel free to re-raise prior-round findings if they disagree with a rejection. Summaries:

- **R1** (2026-04-23, 8 auditors: Gemini 2.5, Grok, Qwen, Kimi, DeepSeek, ChatGPT, Claude-fresh, Perplexity). 15 findings applied, 4 false positives, 7 rejected as design/WARNING-covered. Pre-mainnet.
- **R2** (2026-04-23, Claude fresh). 1 CRITICAL (sp_settle phantom reward) + 1 MEDIUM (redeem coll=0 grief) + 1 LOW (WARNING text) — all fixed. Pre-mainnet.
- **R3** (2026-04-23, Gemini 3.1). NEW-C01 (arbitrary redemption target) raised as CRITICAL. Addressed by adding WARNING (9) disclosure.
- **R3.1** (2026-04-24, Gemini 3.1 + Claude fresh). Both GREEN. Pre-mainnet.
- **R4** (this submission). Post-mainnet; first round where the target is the deployed bytecode rather than the source.

Full per-finding detail is in `audit/AUDIT_TRACKING.md`, `audit/AUDIT_R1_SUBMISSION.md`, `audit/AUDIT_R2_SUBMISSION.md`, `audit/AUDIT_R3_SUBMISSION.md`. R3.1 was handled as an addendum inside R3 with Gemini re-verdict.

---

## 6. On-chain WARNING text (exactly as stored in the bytecode const)

Readable by anyone via `#[view] read_warning()`. Disclosure to end users is the primary mitigation vehicle for everything short of fund-loss.

> ONE is an immutable stablecoin contract on Aptos that depends on Pyth Network's on-chain price feed for APT/USD. If Pyth degrades or misrepresents its oracle, ONE's peg mechanism breaks deterministically - users can wind down via self-close without any external assistance, but new mint/redeem operations become unreliable or frozen. one is immutable = bug is real. Audit this code yourself before interacting. KNOWN LIMITATIONS: (1) Stability Pool enters frozen state when product_factor would drop below 1e9 - protocol aborts further liquidations rather than corrupt SP accounting, accepting bad-debt accumulation past the threshold. (2) Sustained large-scale activity over decades may asymptotically exceed u64 bounds on pending SP rewards. (3) Liquidation seized collateral is distributed in priority: liquidator bonus first (nominal 2.5 percent of debt value, being 25 percent of the 10 percent liquidation bonus), then 2.5 percent reserve share (also 25 percent of bonus), then SP absorbs the remainder and the debt burn. At CR roughly 110% to 150% the SP alone covers the collateral shortfall. At CR below ~5% the liquidator may take the entire remaining collateral, reserve and SP receive zero, and SP still absorbs the full debt burn. (4) 25 percent of each fee is burned, creating a structural 0.25 percent aggregate supply-vs-debt gap per cycle (which rises to 1 percent during SP-empty windows because the remaining 75 percent also burns); individual debtors also face a 1 percent per-trove shortfall because only 99 percent is minted while 100 percent is needed to close - full protocol wind-down requires secondary-market ONE for the last debt closure. (5) Self-redemption (redeem against own trove) is allowed and behaves as partial debt repayment plus collateral withdrawal with a 1 percent fee. (6) Pyth is pull-based on Aptos - callers must ensure price is fresh (within 60 seconds) via pyth::update_price_feeds VAA update before invoking any ONE entry that reads the oracle. (7) Extreme low-price regimes may cause transient aborts in redeem paths when requested amounts exceed u64 output bounds; use smaller amounts and retry. (8) PERMANENT ORACLE FREEZE: if the Pyth package at 0x7e78... is upgraded in a breaking way, the APT/USD feed id 0x03ae4d... is de-registered, or the feed ever becomes permanently unavailable for any reason, the oracle-dependent entries (open_trove, redeem, liquidate, redeem_from_reserve, and their *_pyth wrappers) abort permanently. Oracle-free escape hatches remain fully open: close_trove lets any trove owner reclaim their collateral by burning the full trove debt in ONE (acquiring the 1 percent close deficit via secondary market if needed); add_collateral lets owners top up existing troves without touching the oracle; sp_deposit, sp_withdraw, and sp_claim let SP depositors manage and exit their positions and claim any rewards accumulated before the freeze. Protocol-owned APT held in reserve_coll becomes permanently locked because redeem_from_reserve requires the oracle. No admin override exists; the freeze is final. (9) REDEMPTION vs LIQUIDATION are two separate mechanisms. liquidate is health-gated (requires CR below 150 percent) and applies a penalty bonus to the liquidator, the reserve, and the SP; healthy troves cannot be liquidated by anyone. redeem has no health gate on target and executes a value-neutral swap at oracle spot price - the target's debt decreases by net ONE while their collateral decreases by net times 1e8 over price APT, so the target retains full value at spot. Redemption is the protocol peg-anchor: when ONE trades below 1 USD on secondary market, any holder can burn ONE supply by redeeming for APT, pushing the peg back up. The target is caller-specified; there is no sorted-by-CR priority, unlike Liquity V1's sorted list - the economic result for the target is identical to Liquity (made whole at spot), only the redemption ordering differs, and ordering is a peg-efficiency optimization rather than a safety property. Borrowers who want guaranteed long-term APT exposure without the possibility of redemption-induced position conversion should not use ONE troves - use a non-CDP lending protocol instead. Losing optionality under redemption is not the same as losing value: the target is economically indifferent at spot.

---

## 7. Our own R4 self-audit findings (disprove, extend, or escalate)

We did an in-house adversarial read before submitting. None of the below reach MEDIUM. If you can upgrade any of these, do.

### R4-L-01 (LOW) — WARNING (3) text imprecision
WARNING (3) says *"at CR below ~5% … reserve and SP receive zero"*. The liquidator-share / reserve-share / SP-remainder math:

- SP is first driven to zero at CR ≈ 5% (matches text).
- **Reserve** is first driven to zero at CR ≈ 2.5% (NOT 5%).
- Liquidator takes 100% of remaining collateral only at CR < 2.5% (NOT < 5%).

The on-chain text conflates two boundaries. No protocol-behavior impact; text is more pessimistic than actual. Sealed → disclosure-only.

### R4-D-01 (DESIGN / OPERATIONAL) — Bootstrap bad-debt risk
Current state: `total_sp = 0`, sole trove is the genesis trove at 11.08 APT / 5.10 ONE. Liquidation requires `total_sp > debt` (strict). With SP at zero, **no trove can be liquidated by anyone** regardless of CR. If APT drops ~26% (to ~$0.69) the genesis trove crosses LIQ_THRESHOLD (150%) but is still unliquidatable. Protocol enters bad-debt accumulation until SP is seeded or the trove is closed voluntarily.

Not a bug — it's the designed SP-priority liquidation model. We call it out because bootstrap-specific operational risk isn't explicit in the on-chain WARNING.

Questions for R4 auditors:
- Is there an adversarial angle to the zero-SP state beyond *"don't close your trove and hope APT stays up"*?
- Can an attacker open a second trove, seed SP with the minted ONE, liquidate the genesis trove (if unhealthy), and extract bonus at the genesis owner's expense? (We believe yes — this is designed behavior; genesis owner is equally capable of preempting.)

### R4-I-01 (INFO) — PackageRegistry `upgrade_policy = compatible` is misleading
See § 2. An external reviewer inspecting only the registry might conclude the package is upgradable. Immutability actually comes from layers 2 (auth_key=0x0) + 3 (ResourceCap destroyed). Disclosure emphasis needed.

### R4-I-02 (INFO) — `sp_of` view aborts where `sp_settle` saturates
`sp_settle` saturates pending rewards at `u64::MAX` (via u256 intermediates + explicit saturation branch). The read-only `sp_of` view does raw `as u64` casts from u256, which abort on overflow. Asymptotic only (>>1.8e19 raw units of pending reward — see WARNING 2). Funds are recoverable via `sp_claim` which uses `sp_settle`. Frontend-abort edge only.

### R4-I-03 (INFO) — MIN_DEBT enforced per call, not per trove
`open_impl` asserts `debt >= MIN_DEBT` where `debt` is the *added* debt in this call. A user with an existing 5-ONE trove cannot add +0.5 ONE debt in a single `open_trove` call — they must borrow ≥1 ONE. Design choice (dust prevention); frontend should communicate.

### R4-I-04 (INFO) — Asymptotic `coll_usd × 10000` u128 bound
At maximum `coll = u64::MAX = 1.8e19` and a pathological `price_8dec()` ≈ `9.2e26` (i64::MAX mantissa × 1e8 scaling when `abs_e=0`), `coll_usd × 10000` can exceed u128::MAX. Sub-realistic — would require holding ~100× total APT supply at >$1e18/coin. Same structure in `liquidate` health check and `trove_health` view.

### Observations confirmed as non-findings (please re-examine)

- **Reentrancy-safe**: ONE is non-dispatchable (`option::none()` in `create_primary_store_enabled_fungible_asset`); APT has `EAPT_NOT_DISPATCHABLE` per Aptos framework.
- **Liquity-P index math**: `reward_index_coll += sp_coll × product_factor / total_before` uses OLD `product_factor` and OLD `total_before` — this is the mathematically required form; changing either to post-liquidation values would misallocate rewards.
- **SP reset-on-empty** at line 481-483 is safe because `total_sp == 0` implies `sp_positions` table is empty (sp_withdraw removes entries when `initial_balance == 0`).
- **route_fee_fa dust**: 0-amount destroyed via `destroy_zero`; sub-4 amounts skip burn but still route correctly.

---

## 8. Manifest — `Move.toml`

```toml
[package]
name = "ONE"
version = "0.1.3"
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

Local Pyth interface stub lives at `deps/pyth/`. This is the same interface used by every Aptos-native integrator of Pyth; its only purpose is to give the Move compiler the function signatures. The actual implementation lives at the Pyth mainnet package `0x7e78…b387`.

---

## 9. Full source — `sources/ONE.move` (712 lines)

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

    const WARNING: vector<u8> = b"ONE is an immutable stablecoin contract on Aptos that depends on Pyth Network's on-chain price feed for APT/USD. If Pyth degrades or misrepresents its oracle, ONE's peg mechanism breaks deterministically - users can wind down via self-close without any external assistance, but new mint/redeem operations become unreliable or frozen. one is immutable = bug is real. Audit this code yourself before interacting. KNOWN LIMITATIONS: (1) Stability Pool enters frozen state when product_factor would drop below 1e9 - protocol aborts further liquidations rather than corrupt SP accounting, accepting bad-debt accumulation past the threshold. (2) Sustained large-scale activity over decades may asymptotically exceed u64 bounds on pending SP rewards. (3) Liquidation seized collateral is distributed in priority: liquidator bonus first (nominal 2.5 percent of debt value, being 25 percent of the 10 percent liquidation bonus), then 2.5 percent reserve share (also 25 percent of bonus), then SP absorbs the remainder and the debt burn. At CR roughly 110% to 150% the SP alone covers the collateral shortfall. At CR below ~5% the liquidator may take the entire remaining collateral, reserve and SP receive zero, and SP still absorbs the full debt burn. (4) 25 percent of each fee is burned, creating a structural 0.25 percent aggregate supply-vs-debt gap per cycle (which rises to 1 percent during SP-empty windows because the remaining 75 percent also burns); individual debtors also face a 1 percent per-trove shortfall because only 99 percent is minted while 100 percent is needed to close - full protocol wind-down requires secondary-market ONE for the last debt closure. (5) Self-redemption (redeem against own trove) is allowed and behaves as partial debt repayment plus collateral withdrawal with a 1 percent fee. (6) Pyth is pull-based on Aptos - callers must ensure price is fresh (within 60 seconds) via pyth::update_price_feeds VAA update before invoking any ONE entry that reads the oracle. (7) Extreme low-price regimes may cause transient aborts in redeem paths when requested amounts exceed u64 output bounds; use smaller amounts and retry. (8) PERMANENT ORACLE FREEZE: if the Pyth package at 0x7e78... is upgraded in a breaking way, the APT/USD feed id 0x03ae4d... is de-registered, or the feed ever becomes permanently unavailable for any reason, the oracle-dependent entries (open_trove, redeem, liquidate, redeem_from_reserve, and their *_pyth wrappers) abort permanently. Oracle-free escape hatches remain fully open: close_trove lets any trove owner reclaim their collateral by burning the full trove debt in ONE (acquiring the 1 percent close deficit via secondary market if needed); add_collateral lets owners top up existing troves without touching the oracle; sp_deposit, sp_withdraw, and sp_claim let SP depositors manage and exit their positions and claim any rewards accumulated before the freeze. Protocol-owned APT held in reserve_coll becomes permanently locked because redeem_from_reserve requires the oracle. No admin override exists; the freeze is final. (9) REDEMPTION vs LIQUIDATION are two separate mechanisms. liquidate is health-gated (requires CR below 150 percent) and applies a penalty bonus to the liquidator, the reserve, and the SP; healthy troves cannot be liquidated by anyone. redeem has no health gate on target and executes a value-neutral swap at oracle spot price - the target's debt decreases by net ONE while their collateral decreases by net times 1e8 over price APT, so the target retains full value at spot. Redemption is the protocol peg-anchor: when ONE trades below 1 USD on secondary market, any holder can burn ONE supply by redeeming for APT, pushing the peg back up. The target is caller-specified; there is no sorted-by-CR priority, unlike Liquity V1's sorted list - the economic result for the target is identical to Liquity (made whole at spot), only the redemption ordering differs, and ordering is a peg-efficiency optimization rather than a safety property. Borrowers who want guaranteed long-term APT exposure without the possibility of redemption-induced position conversion should not use ONE troves - use a non-CDP lending protocol instead. Losing optionality under redemption is not the same as losing value: the target is economically indifferent at spot.";

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

---

## 10. On-chain bytecode (14173 bytes, SHA-256 `5f197f105440deba82f3419e912e40a461a7cca368d520988e27f7d88f94d92a`)

Hex dump, 48 bytes per line. This is the literal byte sequence of `modules[0].bytecode` returned by `GET /accounts/0x85ee9c43…/modules`, with the leading `0x` stripped. It is the authoritative artifact — the source in § 9 is verified (§ 3) to compile to exactly this.

```
a11ceb0b0900000a0c0100220222870103a901a80504d10646059707d50407ec0bee0f08da1b6006ba1c822310bc3f91
060acd45e1010cae47b9260de76d36000001160118012c0139013b01520158015b016101030170027f028801024d028f
0100010600000406000007060000080600001006000013080001150701000102170b00021b0600021d0600021f080001
210600032b040200000000002d0600002f06000035060000360800043807010000053a0600003c060000430600004506
00004606000048060000490600025a0000016e02000b7207000d8a0107000e8c0107000f8e010700004d000100010101
004e0001000100004f000200010101015004020108010101005105000001000653060700010101045408090100010101
0155020a010801010100560b0000010000570c000001010107590d0e0108010101085c050200010101005d0f00000100
0206111200010101035e1415020200010101025f17000108010101036018190202000101010962080001060101010063
0212000101010364141c0202000101010065050e0001000366181e02030001010102671f000001010101682122000101
0102590d0e01080101010069050000010101075f0f0000010101006a050000010101046b090801000101010a6c001200
010101016d252600010101046f000901000101010b71272800010101077329000001010101742a0a0108010101017502
260001010102762a2b0001010102772a2c0001010102782d2e010801010101792a2f00010101037a0030020704010101
007b001500010101007c060000010101027d330e00010101007e3600000101010c800137000001010100810138000001
00028201390e000101010083013a000001000384013c000200000101010085013e00000101010086013f000001010100
870112010001000d89012740000101010c8b014142000101010e8d014344000101010e90014344000101010e91014312
000101010e92014312000101010f93014515000101010f94014512000101010f95014512000101010096010027000101
01009701470000010101009801470e0001000099010c0000010101029a010a120108010101009b014a0000010101009c
014d0000010101009d01001200010101029e010e0000010101009f0105000001010100a001500000010000a1010c0000
01010100a20102540001010100a3010c000001010100a401005b0001010100a50102540001010100a601025d00010101
0303060707030a030e130f161013111a13131513112018161c0711241f0122032603281328311134113b311342161148
114b114e0e3110311152313113311156115715311159000104010501080701060b0601090001060c02060c0501081201
0900010b11010900010b0601090002060c0b0601080702060c0303060c0b060109000301081902050819020b06010807
08190106081901030205080d02060b0c02090009010900010101080a020b06010900081902070b0c0209000901090001
070901010801030307080507080d01060901010608050109010206080908190108170106080b010c0405070805080d0c
01080002060c0a0201081a010a0201081b0706081a0b110104081b081b02081b081b0106081a0108080108090206081a
0b06010900010b0601080a01080b010b0c02090009010205080e08081a0b0601080705081a081a081a081a081a020708
19030108031c0708050406080d03030304040404040403040404030404040303030c081907040c081903060c050a0a02
02060c0a0a020305081903020608080302070805081901081803070b0c0209000901090009010e03070805040106080d
03030303030819081907080d070303060c030304060c03030a0a0201081c02081c0301081d0106081d01081e0106081e
09081d081e081e03030303040403060c030501080f07070805040303081908190c03060c030a0a020108040b07080504
03030307080d0101081908190c04060c03050a0a02010802020308190207080505020507080501081504050708050819
07080e030303030506080506080e0303030108130108141707080e04040403010f0f0f01010f030f030f030107030c08
190c01010816040507080507080e0c0503030404040706080506080d04030303030203030206080506080d034f4e450c
43617044657374726f7965640663616c6c65720974696d657374616d700f436f6c6c61746572616c4164646564047573
657206616d6f756e74094665654275726e65640a4c6971756964617465640a6c697175696461746f7206746172676574
046465627412636f6c6c5f746f5f6c697175696461746f720a636f6c6c5f746f5f73700f636f6c6c5f746f5f72657365
7276650e636f6c6c5f746f5f7461726765740852656465656d6564076f6e655f616d7408636f6c6c5f6f757408526567
6973747279086d65746164617461064f626a656374066f626a656374084d657461646174610e66756e6769626c655f61
737365740c6170745f6d65746164617461086d696e745f726566074d696e74526566086275726e5f726566074275726e
526566086665655f706f6f6c0d46756e6769626c6553746f72650a6665655f657874656e6409457874656e6452656607
73705f706f6f6c0973705f657874656e640c73705f636f6c6c5f706f6f6c0e73705f636f6c6c5f657874656e640c7265
73657276655f636f6c6c0e726573657276655f657874656e640874726561737572790f74726561737572795f65787465
6e640674726f7665730a536d6172745461626c650b736d6172745f7461626c650554726f76650c73705f706f73697469
6f6e730253500a746f74616c5f6465627408746f74616c5f73700e70726f647563745f666163746f7210726577617264
5f696e6465785f6f6e65117265776172645f696e6465785f636f6c6c0f5265736572766552656465656d65640b526573
6f7572636543617003636170064f7074696f6e066f7074696f6e105369676e65724361706162696c697479076163636f
756e740f5265776172645361747572617465641570656e64696e675f6f6e655f7472756e63617465641670656e64696e
675f636f6c6c5f7472756e63617465640f696e697469616c5f62616c616e636510736e617073686f745f70726f647563
7412736e617073686f745f696e6465785f6f6e6513736e617073686f745f696e6465785f636f6c6c095350436c61696d
656408636f6c6c5f616d740b53504465706f73697465640a535057697468647265770a636f6c6c61746572616c0b5472
6f7665436c6f7365640b54726f76654f70656e65640e6e65775f636f6c6c61746572616c086e65775f646562740a6164
6465645f646562740570726963650a70726963655f386465630d6d657461646174615f616464720e6f626a6563745f61
6464726573730b696e69745f6d6f64756c65107265736f757263655f6163636f756e741d72657472696576655f726573
6f757263655f6163636f756e745f63617004736f6d6511616464726573735f746f5f6f626a65637411696e69745f6d6f
64756c655f696e6e65720e6164645f636f6c6c61746572616c167072696d6172795f66756e6769626c655f73746f7265
0877697468647261770d46756e6769626c654173736574067369676e65720a616464726573735f6f66086164645f696d
706c08636f6e7461696e73076465706f7369740a626f72726f775f6d7574056576656e7404656d69740a636c6f73655f
636f737406626f72726f770a636c6f73655f696d706c0672656d6f7665046275726e1d67656e65726174655f7369676e
65725f666f725f657874656e64696e670b636c6f73655f74726f76650b64657374726f795f6361700c64657374726f79
5f736f6d650b6e6f775f7365636f6e6473136372656174655f6e616d65645f6f626a6563740e436f6e7374727563746f
72526566046e6f6e6506737472696e67047574663806537472696e672b6372656174655f7072696d6172795f73746f72
655f656e61626c65645f66756e6769626c655f61737365741b6f626a6563745f66726f6d5f636f6e7374727563746f72
5f7265660d6372656174655f6f626a6563741167656e65726174655f6d696e745f7265661167656e65726174655f6275
726e5f7265660c6372656174655f73746f72651367656e65726174655f657874656e645f726566036e65770969735f73
65616c6564096c697175696461746507657874726163740e6c69717569646174655f7079746804707974681e75706461
74655f70726963655f66656564735f776974685f66756e646572096f70656e5f696d706c046d696e740c726f7574655f
6665655f6661036164640a6f70656e5f74726f76650f6f70656e5f74726f76655f7079746805706f7731301070726963
655f6964656e7469666965720d66726f6d5f627974655f7665630f50726963654964656e746966696572176765745f70
726963655f6e6f5f6f6c6465725f7468616e055072696365096765745f70726963650349363403693634086765745f65
78706f0d6765745f74696d657374616d70086765745f636f6e660f6765745f69735f6e65676174697665196765745f6d
61676e69747564655f69665f6e65676174697665196765745f6d61676e69747564655f69665f706f7369746976650c72
6561645f7761726e696e670672656465656d0b72656465656d5f696d706c1372656465656d5f66726f6d5f7265736572
76650762616c616e63651872656465656d5f66726f6d5f726573657276655f707974680b72656465656d5f707974680f
726573657276655f62616c616e63650c64657374726f795f7a65726f0873705f636c61696d0973705f736574746c650a
73705f6465706f7369740573705f6f660b73705f776974686472617706746f74616c730c74726f76655f6865616c7468
0874726f76655f6f6685ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab8738700000000000000
000000000000000000000000000000000000000000000000017e783b349d3e89cf5931af376ebeadbfab855b3fa239b7
ada8f5a92fbea6b387052085ee9c43688e37bb2050327467c3a6ebcfa37375a8209df327dd77c0aab8738705200047a3
e13465172e10661e20b7b618235e9c7e62a365d315e91cf1ef647321c905200000000000000000000000000000000000
00000000000000000000000000000a0a0204034f4e450a020201310a0201000a02212003ae4db29ed4ae33d323568895
aa00337e658e348b37509f5372ae51f0af00d50a02e421e2214f4e4520697320616e20696d6d757461626c6520737461
626c65636f696e20636f6e7472616374206f6e204170746f73207468617420646570656e6473206f6e2050797468204e
6574776f726b2773206f6e2d636861696e207072696365206665656420666f72204150542f5553442e20496620507974
68206465677261646573206f72206d6973726570726573656e747320697473206f7261636c652c204f4e452773207065
67206d656368616e69736d20627265616b732064657465726d696e6973746963616c6c79202d2075736572732063616e
2077696e6420646f776e207669612073656c662d636c6f736520776974686f757420616e792065787465726e616c2061
7373697374616e63652c20627574206e6577206d696e742f72656465656d206f7065726174696f6e73206265636f6d65
20756e72656c6961626c65206f722066726f7a656e2e206f6e6520697320696d6d757461626c65203d20627567206973
207265616c2e204175646974207468697320636f646520796f757273656c66206265666f726520696e74657261637469
6e672e204b4e4f574e204c494d49544154494f4e533a202831292053746162696c69747920506f6f6c20656e74657273
2066726f7a656e207374617465207768656e2070726f647563745f666163746f7220776f756c642064726f702062656c
6f7720316539202d2070726f746f636f6c2061626f7274732066757274686572206c69717569646174696f6e73207261
74686572207468616e20636f7272757074205350206163636f756e74696e672c20616363657074696e67206261642d64
65627420616363756d756c6174696f6e207061737420746865207468726573686f6c642e20283229205375737461696e
6564206c617267652d7363616c65206163746976697479206f7665722064656361646573206d6179206173796d70746f
746963616c6c79206578636565642075363420626f756e6473206f6e2070656e64696e6720535020726577617264732e
20283329204c69717569646174696f6e207365697a656420636f6c6c61746572616c2069732064697374726962757465
6420696e207072696f726974793a206c697175696461746f7220626f6e757320666972737420286e6f6d696e616c2032
2e352070657263656e74206f6620646562742076616c75652c206265696e672032352070657263656e74206f66207468
652031302070657263656e74206c69717569646174696f6e20626f6e7573292c207468656e20322e352070657263656e
7420726573657276652073686172652028616c736f2032352070657263656e74206f6620626f6e7573292c207468656e
205350206162736f726273207468652072656d61696e64657220616e64207468652064656274206275726e2e20417420
435220726f7567686c79203131302520746f20313530252074686520535020616c6f6e6520636f766572732074686520
636f6c6c61746572616c2073686f727466616c6c2e2041742043522062656c6f77207e352520746865206c6971756964
61746f72206d61792074616b652074686520656e746972652072656d61696e696e6720636f6c6c61746572616c2c2072
65736572766520616e642053502072656365697665207a65726f2c20616e64205350207374696c6c206162736f726273
207468652066756c6c2064656274206275726e2e202834292032352070657263656e74206f6620656163682066656520
6973206275726e65642c206372656174696e672061207374727563747572616c20302e32352070657263656e74206167
6772656761746520737570706c792d76732d646562742067617020706572206379636c65202877686963682072697365
7320746f20312070657263656e7420647572696e672053502d656d7074792077696e646f777320626563617573652074
68652072656d61696e696e672037352070657263656e7420616c736f206275726e73293b20696e646976696475616c20
646562746f727320616c736f2066616365206120312070657263656e74207065722d74726f76652073686f727466616c
6c2062656361757365206f6e6c792039392070657263656e74206973206d696e746564207768696c6520313030207065
7263656e74206973206e656564656420746f20636c6f7365202d2066756c6c2070726f746f636f6c2077696e642d646f
776e207265717569726573207365636f6e646172792d6d61726b6574204f4e4520666f7220746865206c617374206465
627420636c6f737572652e202835292053656c662d726564656d7074696f6e202872656465656d20616761696e737420
6f776e2074726f76652920697320616c6c6f77656420616e642062656861766573206173207061727469616c20646562
742072657061796d656e7420706c757320636f6c6c61746572616c207769746864726177616c20776974682061203120
70657263656e74206665652e2028362920507974682069732070756c6c2d6261736564206f6e204170746f73202d2063
616c6c657273206d75737420656e73757265207072696365206973206672657368202877697468696e20363020736563
6f6e6473292076696120707974683a3a7570646174655f70726963655f66656564732056414120757064617465206265
666f726520696e766f6b696e6720616e79204f4e4520656e747279207468617420726561647320746865206f7261636c
652e202837292045787472656d65206c6f772d707269636520726567696d6573206d6179206361757365207472616e73
69656e742061626f72747320696e2072656465656d207061746873207768656e2072657175657374656420616d6f756e
74732065786365656420753634206f757470757420626f756e64733b2075736520736d616c6c657220616d6f756e7473
20616e642072657472792e20283829205045524d414e454e54204f5241434c4520465245455a453a2069662074686520
50797468207061636b616765206174203078376537382e2e2e20697320757067726164656420696e206120627265616b
696e67207761792c20746865204150542f55534420666565642069642030783033616534642e2e2e2069732064652d72
6567697374657265642c206f722074686520666565642065766572206265636f6d6573207065726d616e656e746c7920
756e617661696c61626c6520666f7220616e7920726561736f6e2c20746865206f7261636c652d646570656e64656e74
20656e747269657320286f70656e5f74726f76652c2072656465656d2c206c69717569646174652c2072656465656d5f
66726f6d5f726573657276652c20616e64207468656972202a5f70797468207772617070657273292061626f72742070
65726d616e656e746c792e204f7261636c652d667265652065736361706520686174636865732072656d61696e206675
6c6c79206f70656e3a20636c6f73655f74726f7665206c65747320616e792074726f7665206f776e6572207265636c61
696d20746865697220636f6c6c61746572616c206279206275726e696e67207468652066756c6c2074726f7665206465
627420696e204f4e452028616371756972696e672074686520312070657263656e7420636c6f73652064656669636974
20766961207365636f6e64617279206d61726b6574206966206e6565646564293b206164645f636f6c6c61746572616c
206c657473206f776e65727320746f70207570206578697374696e672074726f76657320776974686f757420746f7563
68696e6720746865206f7261636c653b2073705f6465706f7369742c2073705f77697468647261772c20616e64207370
5f636c61696d206c6574205350206465706f7369746f7273206d616e61676520616e6420657869742074686569722070
6f736974696f6e7320616e6420636c61696d20616e79207265776172647320616363756d756c61746564206265666f72
652074686520667265657a652e2050726f746f636f6c2d6f776e6564204150542068656c6420696e2072657365727665
5f636f6c6c206265636f6d6573207065726d616e656e746c79206c6f636b656420626563617573652072656465656d5f
66726f6d5f7265736572766520726571756972657320746865206f7261636c652e204e6f2061646d696e206f76657272
696465206578697374733b2074686520667265657a652069732066696e616c2e2028392920524544454d5054494f4e20
7673204c49515549444154494f4e206172652074776f207365706172617465206d656368616e69736d732e206c697175
6964617465206973206865616c74682d6761746564202872657175697265732043522062656c6f772031353020706572
63656e742920616e64206170706c69657320612070656e616c747920626f6e757320746f20746865206c697175696461
746f722c2074686520726573657276652c20616e64207468652053503b206865616c7468792074726f7665732063616e
6e6f74206265206c69717569646174656420627920616e796f6e652e2072656465656d20686173206e6f206865616c74
682067617465206f6e2074617267657420616e6420657865637574657320612076616c75652d6e65757472616c207377
6170206174206f7261636c652073706f74207072696365202d2074686520746172676574277320646562742064656372
6561736573206279206e6574204f4e45207768696c6520746865697220636f6c6c61746572616c206465637265617365
73206279206e65742074696d657320316538206f766572207072696365204150542c20736f2074686520746172676574
2072657461696e732066756c6c2076616c75652061742073706f742e20526564656d7074696f6e206973207468652070
726f746f636f6c207065672d616e63686f723a207768656e204f4e45207472616465732062656c6f7720312055534420
6f6e207365636f6e64617279206d61726b65742c20616e7920686f6c6465722063616e206275726e204f4e4520737570
706c792062792072656465656d696e6720666f72204150542c2070757368696e672074686520706567206261636b2075
702e20546865207461726765742069732063616c6c65722d7370656369666965643b207468657265206973206e6f2073
6f727465642d62792d4352207072696f726974792c20756e6c696b65204c697175697479205631277320736f72746564
206c697374202d207468652065636f6e6f6d696320726573756c7420666f722074686520746172676574206973206964
656e746963616c20746f204c69717569747920286d6164652077686f6c652061742073706f74292c206f6e6c79207468
6520726564656d7074696f6e206f72646572696e6720646966666572732c20616e64206f72646572696e672069732061
207065672d656666696369656e6379206f7074696d697a6174696f6e20726174686572207468616e2061207361666574
792070726f70657274792e20426f72726f776572732077686f2077616e742067756172616e74656564206c6f6e672d74
65726d20415054206578706f7375726520776974686f75742074686520706f73736962696c697479206f662072656465
6d7074696f6e2d696e647563656420706f736974696f6e20636f6e76657273696f6e2073686f756c64206e6f74207573
65204f4e452074726f766573202d207573652061206e6f6e2d434450206c656e64696e672070726f746f636f6c20696e
73746561642e204c6f73696e67206f7074696f6e616c69747920756e64657220726564656d7074696f6e206973206e6f
74207468652073616d65206173206c6f73696e672076616c75653a20746865207461726765742069732065636f6e6f6d
6963616c6c7920696e646966666572656e742061742073706f742e14636f6d70696c6174696f6e5f6d65746164617461
090003322e3003322e33126170746f733a3a6d657461646174615f7631dd051301000000000000000c455f434f4c4c41
544552414c00020000000000000007455f54524f56450003000000000000000a455f444542545f4d494e000400000000
00000007455f5354414c4500050000000000000008455f53505f42414c00060000000000000008455f414d4f554e5400
070000000000000008455f54415247455400080000000000000009455f4845414c54485900090000000000000011455f
53505f494e53554646494349454e54000a0000000000000016455f494e53554646494349454e545f5245534552564500
0b000000000000000c455f50524943455f5a45524f000c000000000000000c455f4558504f5f424f554e44000d000000
0000000012455f444543494d414c5f4f564552464c4f57000e0000000000000009455f505f434c494646000f00000000
0000000c455f50524943455f4558504f0010000000000000000b455f50524943455f4e45470011000000000000000c45
5f4e4f545f4f524947494e0012000000000000000a455f4341505f474f4e4500130000000000000011455f5052494345
5f554e4345525441494e000c0852656465656d6564010400094665654275726e6564010400095350436c61696d656401
04000a4c6971756964617465640104000a535057697468647265770104000b53504465706f73697465640104000b5472
6f7665436c6f7365640104000b54726f76654f70656e65640104000c43617044657374726f7965640104000f436f6c6c
61746572616c41646465640104000f5265736572766552656465656d65640104000f5265776172645361747572617465
640104000a0570726963650101000573705f6f6601010006746f74616c730101000874726f76655f6f66010100096973
5f7365616c65640101000a636c6f73655f636f73740101000c726561645f7761726e696e670101000c74726f76655f68
65616c74680101000d6d657461646174615f616464720101000f726573657276655f62616c616e636501010000020202
05030301020205050603020201060303020709050a050b030c030d030e030f0304020405050a0511031203050215140b
06010807190b060108071a08081c08091e0b0601080a20080b220b0601080a23080b240b0601080a25080b260b060108
0a27080b280b0601080a29080b2a0b0c0205080d2e0b0c0205080e300331033204330434040f02030505110312031002
01370b1101081213020305053d013e010e02043f03400441044204140203050511034403150202050506031602020505
06030d020247030b03170203050547030b0318020405054a034b034c030001000000021101020201000105000507002b
05100038000204000000070e0a00070111050c010a000b01380112072d070b00070238021108020901040105100f0700
2b051001140c020a000b020b0138030c030b00110b0b03110c020c000001051b2c0e01110d0c020a0206000000000000
000024042a07002a050c030a0310020a00380404260a031003140b0138050b030f020a0038060c040a041004140a0216
0b040f04150b000b0212013807020b0301060200000000000000270606000000000000002712010001051d1307002b05
0c010a0110020a003804040f0b0110020b003808100514020b0101060000000000000000021400000105234a0a00110b
0c0107002a050c020a0210020a01380404440a020f020a0138090c030e031005140600000000000000002404410a0210
060b000a021000140e03100514380311160a021007140e03100514170a020f07150b010e031004140e03100514120e38
0a0a02100811170c040e040b021003140e03100414380b020b000105210b00010b020106020000000000000027190104
010500060a00110b0b001114111a021b01040107001b0a00110b070121041707002907041307002c071307380c010b00
110b111d1200380d020b0001061200000000000000270b00010611000000000000002708000000324f0a000703111e0c
020e02380e07031120070411203108070511200705112011210e02380f0c030a00110b0c040a0411230c050a0411230c
060a0411230c070a0411230c080b0411230c090b000a030a010e0211240e0211250e050a0338100e0511270e060b0338
100e0611270e070a0138100e0711270e080a0138100e0811270e090b0138100e09112738113812060000000000000000
06000000000000000032000064a7b3b6e00d000000000000000032000000000000000000000000000000003200000000
00000000000000000000000012052d05022901000000040700290720022a0104010535ad0207002a050c020a0210020a
01380404a70211010c030a0210020a0138080c040a041005140c050b041004140c060a06350a03183200e1f505000000
0000000000000000001a32102700000000000000000000000000001832983a00000000000000000000000000000a0535
182304a1020a021009140a0524049b020a021009140c070a02100a140a070a051735180a07351a0c080a083200ca9a3b
000000000000000000000000260495020a053532e8030000000000000000000000000000183210270000000000000000
0000000000001a0c090a0932c40900000000000000000000000000001832102700000000000000000000000000001a0c
0a0a0932c40900000000000000000000000000001832102700000000000000000000000000001a0c0b0a05350b091632
00e1f505000000000000000000000000180a031a0c090a06350c0c0a090a0c240492020b0c0c0d0b0d340c0e0b0a3200
e1f505000000000000000000000000180a031a0c0f0a0e350c100a0f0a1024048f020a100c110b11340c120b100a1235
170c130b0b3200e1f505000000000000000000000000180b031a0c140a140a1324048c020b130c150b15340c160a0e0a
12170a16170c170b060a0e170c180a020f020a013809010a021007140a05170a020f07150a02100b11170c190e190a02
100c140a05380b0c1a0a0210060b1a11160a02100d140a17350a02100a14180a07351a160a020f0d150a020f0a0c1b0b
080b1b150b070a05170a020f09150a02100811170c1c0e1c0a021003140b0e380b0c1d0d1d0a12112b0c1a0a00110b0b
1a111a0d1d0a16112b0c1a0a02100e140b1a38050a02100f140b1d38050a18060000000000000000240489020e1c0b02
1003140a18380b0c1a0a010b1a111a0b00110b0b010b050b120b170b160b1812033813020b020105fe010b140c15058a
010b0f0c1105760b090c0d05640b00010b0201060e00000000000000270b00010b0201060900000000000000270b0001
0b0201060800000000000000270b00010b0201060700000000000000272c0104010500070a000b02112d0b000b01112a
022e000001053d8a010a020600e1f50500000000260488010e01110d0c0307002a050c0411010c050a0410020a003804
0c060a060483010a0410020a0038080c070a071004140c080b071005140c090b080b03160c0a0b090a02160c0b0a0a35
0b05183200e1f5050000000000000000000000001a32102700000000000000000000000000001832204e000000000000
00000000000000000a0b351826047f0a041003140b0138050a0235326400000000000000000000000000000018321027
00000000000000000000000000001a340c0c0a0410100a020a0c17112f0c0d0a0410100b0c112f0c0e0a000b0d111a0a
040b0e11300b0604770a040f020a0038060c0f0a0f0f040c100a0a0b10150b0f0f050c100a0b0b10150a041007140a02
160b040f07150b000b0a0b0b0b02120f3814020a040f020a000a0a0a0b120d381505680b040106010000000000000027
0600000000000000000c080600000000000000000c090520060300000000000000273201040105101007002b05100114
0c030a000b030b0138030c040b00110b0b040b02112e02330104010510130a000b03112d07002b051001140c040a000b
040b0138030c050b00110b0b050b02112e023400000001170a0006260000000000000025041532010000000000000000
000000000000000c010a000600000000000000002404130b01320a000000000000000000000000000000180c010b0006
0100000000000000170c0005060b0102060d000000000000002701000000466607061135063c0000000000000011360c
000e0011370c010e0011380c020e0011390c030e00113a0c04111d0c050a03063c00000000000000160a052604640b03
0b05060a00000000000000162504620e02113b04600e02113c0c060a0606120000000000000025045e0e01113b035c0e
01113d350c070a07320000000000000000000000000000000024045a0b04353210270000000000000000000000000000
1832c80000000000000000000000000000000a07182504580a060608000000000000002604500b070b06060800000000
0000001711341a0c080a08320000000000000000000000000000000024044e0b0802060b00000000000000270b070608
000000000000000b06171134180c08054806130000000000000027060b00000000000000270610000000000000002706
0c0000000000000027060f000000000000002706040000000000000027060400000000000000273e0100000002070702
3f0104010500080a00110b0b000b010b021140111a02410104010549540a010600e1f5050000000026045007002a050c
0211010c030a013532640000000000000000000000000000001832102700000000000000000000000000001a340c040a
010a0417353200e1f505000000000000000000000000180b031a340c050a02100e1438160a0526044a0a000a02100014
0a0138030c060d060b04112b0c070a0210060b0611160a020b0711300a02101111170c080e080b02100e140a05380b0c
070a00110b0b07111a0b00110b0b010b0512063817020b00010b0201060a00000000000000270b000106060000000000
000027430104010500070a000b02112d0b000b0111410240000001054cbb010a010600e1f505000000002604b7010700
2a050c030a0310020a02380404b10111010c040a01353264000000000000000000000000000000183210270000000000
0000000000000000001a340c050a010a05170c060a06353200e1f505000000000000000000000000180b041a340c070a
030f020a0238060c080a081005140a062604a9010a081004140a072604a1010a081005140a06170a080f05150a081004
140a07170a080f04150a0810051406000000000000000021049a01080c090b090492010a081005140600000000000000
0021048b010b0801080c0a0b0a0485010a000a031000140a0138030c0b0d0b0b05112b0c0c0a0310060b0b11160a030b
0c11300a031007140b06170a030f07150b00110b0b020b010a07120438180a03100811170c0d0e0d0b031003140b0738
0b020b00010b0301060100000000000000270b08100414060000000000000000240c0a05570b00010b03010b08010603
00000000000000270a081005140600e1f50500000000260c09054b0b00010b03010b0801060100000000000000270b00
010b03010b0801060700000000000000270b00010b0301060700000000000000270b0001060600000000000000274401
040105000b0a000b03112d0a00110b0b000b010b021140111a024501000105000607002b05100e14381602300000004f
530e01110d0c020a0206000000000000000021040c0b00010b011146020b023532c40900000000000000000000000000
001832102700000000000000000000000000001a340c020a0206000000000000000024031905240d010a02112b0c030a
0010060b0311160b02120238190e01110d0c020a020600000000000000002104300b00010b011146020a001009140600
0000000000000021043b0b0010060b011116020a001012140b0138050a001013140b02350a00100a14180a0010091435
1a160b000f131502470104010551130b00110b0c0107002a050c020a0210140a01381a040f0b020b011148020b020106
050000000000000027490104010553570a010600000000000000002404530a00110b0c0207002a050c030b000a031000
140a0138030c040a03100c140b0438050a0310091406000000000000000021031d052132000064a7b3b6e00d00000000
000000000a030f0a150a0310140a02381a04430a030a0211480a030f140a02381b0c050a051015140a01160b050f1515
0a031009140a01160b030f09150b020b01120b381c020a030f140a020a010a03100a140a031013140a03100d14120938
1d05360b0001060600000000000000274a01000105554907002b050c010a0110140a00381a04430a0110140b00381e0c
020a021015144d0a01100a144d180a021016144d1a340a011013140a02101714174d0a021015144d180a021016144d1a
340b01100d140a02101814174d0a021015144d180b021016144d1a34020b010106000000000000000006000000000000
0000060000000000000000024800000058e5010a000f140a01381b0c020a021016140c030a021017140c040a02101814
0c050a021015140c060a0332000000000000000000000000000000002104e001080c070b0704300a00100a140a020f16
150a001013140a020f17150b00100d140b020f1815020a001013140b04174d0a064d180a034d1a0c080a00100d140b05
174d0a064d180a034d1a0c090b064d0a00100a144d180b034d1a0c0a0a084affffffffffffffff000000000000000000
000000000000000000000000000000240c0b0a094affffffffffffffff00000000000000000000000000000000000000
0000000000240c0c0a0b04dd014affffffffffffffff0000000000000000000000000000000000000000000000000c0d
0b0d340c0e0a0c04da014affffffffffffffff0000000000000000000000000000000000000000000000000c0f0b0f34
0c100a0a4affffffffffffffff0000000000000000000000000000000000000000000000002404d7014affffffffffff
ffff0000000000000000000000000000000000000000000000000c110b11340c120a0b04d401080c130b13037b058001
0a010b0b0b0c1208381f0a020f150c140b120b14150a00100a140a020f16150a001013140a020f17150a00100d140b02
0f18150a0e06000000000000000024039d0105ab010a00101911170c150e150a001012140a0e380b0c160a010b16111a
0a100600000000000000002404d1010a00101a11170c170e170b00100f140a10380b0c160a010b16111a0a0e06000000
00000000002404cc01080c180b1804cb010b010b0e0b10120a382002020a10060000000000000000240c1805c3010b00
0105bd010a0c0c1305780b0a0c1105710b090c0f05680b080c0d05610a06060000000000000000210c07051b4b010401
055a5a0a010600000000000000002404560b00110b0c0207002a050c030a0310140a02381a04520a030a0211480a030f
140a02381b0c040a041015140a0126044c0a041015140a01170a040f15150a031009140a01170a030f09150b04101514
060000000000000000210a03100b11170c050a020e050a03100c140a01380b111a04490b030f140a023821010b020b01
120c3822020b030105440b03010b0401060500000000000000270b0301060500000000000000270b0001060600000000
000000274c010001051d1307002b050c000a001007140a001009140a00100a140a001013140b00100d14024d01000105
5c3e07002b050c010a0110020a003804030e0b0101060000000000000000060000000000000000060000000000000000
020b0110020b0038080c020a0210051406000000000000000021041f0b02100414060000000000000000060000000000
0000000211010c030a02100414350b03183200e1f5050000000000000000000000001a32102700000000000000000000
00000000180a02100514351a340a021004140b021005140c040c050c070b050b040b07024e010001055e1907002b050c
010a0110020a00380404140b0110020b0038080c020a021004140b02100514020b010106000000000000000006000000
00000000000205000501050e050c0d000d0105030510050d05110512050705060514050a05080502050b05040513050f
09000901090209030505050900
```

---

## 11. Submission / contact

Send findings as a single markdown reply following the severity/format rubric in § 4. We aggregate all R4 responses and decide:

- LOW/INFO → add to `DEPLOYMENT.md` known-notes section + relevant frontend tooltip.
- MEDIUM → same + prominent user warning on the frontend Home/About page and a notice in the project README.
- HIGH/CRITICAL → prominent exploit advisory, probable migration to a v2 sibling package; current v0.1.3 stays live but is publicly marked unsafe, and the frontend starts pointing users at close-only flows + the new deployment.

We commit to publish all R4 responses verbatim (with attribution if requested, anonymously otherwise) in the audit/ directory of the repo.

Thank you for attacking our code.
