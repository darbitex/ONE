# ONE Supra — Deployment Record

Canonical log of on-chain deployments on Supra L1. Point here first before re-researching addresses.

---

## v0.4.0 — LIVE + SEALED (2026-04-24)

**Status**: LIVE + cryptographically immutable. Fresh empty state (no bootstrap, no genesis trove). Any user can open the first trove.

### Addresses

| | |
|---|---|
| **Package** | `0x2365c9489f7d851ccbfe07c881f8c203a11558760202f45b999c98eafda5c90f` |
| **Module** | `0x2365c9489f7d851ccbfe07c881f8c203a11558760202f45b999c98eafda5c90f::ONE` |
| **ONE FA metadata** | `0xef06314bfb6a3478d24623ba0f57eb5a09291aef3ea5c1abbe4f5f7b0cf28c22` |
| **Oracle (Supra native)** | `0xe3948c9e3a24c51c4006ef2acc44606055117d021158f320062df099c4a94150::supra_oracle_storage`, pair 500 (SUPRA/USDT) |
| **Deployer (DEAD — unsignable)** | `0x2365c9489f7d851ccbfe07c881f8c203a11558760202f45b999c98eafda5c90f` |
| **Chain** | Supra L1 mainnet (chain_id 8) |

### Transactions (in order)

1. **Publish** — `0x052ba1e8c2de1824fc18a6e2028a0fa0bd981608b35c9a642c3a1b02d962c264`
   - Package published. Registry initialized with zero state.
   - Gas: 16714 units × 100 octas = 1,671,400 raw (~0.0167 SUPRA)
   - Block 45251222
2. **Null auth_key** — `0xb3300786dafdecc9dba628b98d700380a0c7f995f52fcb1762940783cd9b4818`
   - `0x1::account::rotate_authentication_key_call` with 32 zero bytes
   - auth_key transitioned from deployer-derived → `0x00…00`
   - Gas: 4 units × 100 octas = 400 raw (~0.000004 SUPRA)

Total deploy spend: 0.016718 SUPRA ≈ **$0.007 USD** at $0.0003668/SUPRA.

### State at deploy

```
is_sealed     : via auth_key = 0x00...00 (verified)
total_debt    : 0                     (no bootstrap trove)
total_sp      : 0                     (no SP base)
product_factor: 1000000000000000000   (= PRECISION = 1e18)
reward_index_one  : 0
reward_index_supra: 0
reserve_balance   : 0
active troves : 0
active SP deposits: 0
WARNING bytes : 5837                  (10 clauses, R4-M-01 oracle-lag disclosure included)
```

### Supersession

v0.4.0 **permanently supersedes** v0.3.0 at `0x4f03319c1ef88680b1209a2e58ed7dafa4a3b1dea761ecbb730011d41e6289b7`. v0.3.0 remains on-chain as a read-only historical record but is not to be used by anyone — it carries 3 unfixable bugs (C-01 phantom reward, M-01 coll-zero grief, L-01 WARNING mislabel), all of which v0.4.0 patches at source + adds R1-R3.1 + R4 hardening + full 10-clause WARNING.

### Launch mode

**Pure launch** — no deployer bootstrap trove, no SP seed. Zero deployer privilege in state, not just in policy. The first trove will be opened by whichever external user calls `open_trove` first, using their own SUPRA at their own discretion.

Consequences:
- Protocol supply starts at 0 ONE circulating.
- First liquidation requires the first SP depositor (strict `total_sp > debt` gate). Early troves before any SP deposit are NOT liquidatable — matches the Aptos R4-D-01 bootstrap operational note.
- Peg anchor via `redeem` / `redeem_from_reserve` stays available once at least one trove exists.

### Source / audit / code

- **Tag**: `v0.4.0-supra` (`git show v0.4.0-supra` for source state at deploy)
- **Commit**: `8b11626` on github.com/darbitex/ONE
- **Delta report** (v0.3.0 → v0.4.0 + Aptos comparison matrix): [`audit/V04_DELTA_REPORT.md`](audit/V04_DELTA_REPORT.md)
- **Bytecode**: 14246 bytes on-chain (25330 bytes package including metadata)
- **Tests**: 24/24 pass locally

### Immutability verification

External reviewers run:

```bash
# Auth_key check — most important layer
curl -s -X POST https://rpc-mainnet.supra.com/rpc/v1/accounts/0x2365c9489f7d851ccbfe07c881f8c203a11558760202f45b999c98eafda5c90f
# expect: authentication_key = "0x0000000000000000000000000000000000000000000000000000000000000000"

# Package upgrade_policy check (reference only — NOT a safety property here)
# Returns policy = 1 (compatible). Immutability is via auth_key layer, not policy.

# Bytecode hash reproducibility
git clone https://github.com/darbitex/ONE
cd ONE/supra
aptos move build-publish-payload \
  --json-output-file /tmp/check.json \
  --named-addresses ONE=0x2365c9489f7d851ccbfe07c881f8c203a11558760202f45b999c98eafda5c90f \
  --bytecode-version 6 --language-version 1
# Compare /tmp/check.json args[1].value[0] against on-chain module bytecode
```

---

## v0.3.0 — DEPRECATED (2026-04-23)

**Status**: on-chain, null-auth'd, but flagged DO-NOT-USE due to 3 source bugs.

| | |
|---|---|
| Package | `0x4f03319c1ef88680b1209a2e58ed7dafa4a3b1dea761ecbb730011d41e6289b7` |
| ONE FA | `0x41422d92c19a82c24cc72a03530862e845ebffe6d6b45c526bab796e0816bc11` |
| Deployer | same as package (null-auth'd) |

State frozen post null-auth:
- Genesis trove: 5555 SUPRA / 1 ONE (deployer's, orphaned forever)
- SP base: 0.99 ONE (deployer's, unreachable)
- `total_debt`: 100_000_000 (1 ONE)

Known bugs see root `/README.md` for plain-English disclosure or `audit/V04_DELTA_REPORT.md` §1 for technical detail.

**Fund at risk**: only the deployer's 5555 SUPRA + 0.99 ONE. No external users opened positions, so no user funds are at risk. The genesis trove remains accessible to redeemers at oracle price if anyone cares to extract it.
