# Deployer Key — Public Proof of Null Auth

The `ONE` package was published from the address below and its `authentication_key` was rotated to `0x00...00` in the same session. This file publishes the full private key so anyone can independently verify that:

1. The published key really derives to the `ONE` deployer address.
2. Signing attempts against the deployer account now fail on-chain because the account's `authentication_key` is zero — the key has no residual power.

Because the account is permanently unsignable, exposing this key has no adversarial value. It is published here as durable, self-contained evidence of the immutability claim.

## Key material

```
Ed25519 private key : 0xc7691ff7feb232bdd81288148ae1d7120bb0e05b54d841ffb5c953617bff44fe
Ed25519 public key  : 0x4d97aa988e8da919f4b9d6abed368eeb392246e0a731f41bc841025174c5bf8d
Derived address     : 0x4f03319c1ef88680b1209a2e58ed7dafa4a3b1dea761ecbb730011d41e6289b7
```

Derivation (any SDK):

```
address = sha3_256(public_key_bytes || 0x00)
```

## Null-auth transactions

```
Testnet (Supra chain_id 6)
  tx : 0x101289a36910b06e76e60244d2f25bcfdb29da6b2cc8adf0970c393b00843d2f
  call: 0x1::account::rotate_authentication_key_call(signer, <32 zero bytes>)

Mainnet (Supra chain_id 8)
  tx : 0x8e06a9e51d88f262d6100041b4a627ef29a51f8d59c1f51174ac2f6fa92003b9
  call: 0x1::account::rotate_authentication_key_call(signer, <32 zero bytes>)
```

After either transaction, reading the account returns:

```
authentication_key = 0x0000000000000000000000000000000000000000000000000000000000000000
```

## Verification

Anyone can confirm the deployer is unsignable on mainnet with:

```bash
curl -s https://rpc-mainnet.supra.com/rpc/v1/accounts/0x4f03319c1ef88680b1209a2e58ed7dafa4a3b1dea761ecbb730011d41e6289b7 \
  | python3 -m json.tool
```

Expected output contains `"authentication_key": "0x00...00"`.

If someone tried to submit a signed transaction from this account using the private key above, the node would reject the signature because the hash of the provided public key does not match `0x00...00`. There is no preimage to zero under `sha3_256`, so no key of any kind can sign for this account ever again.

## Why this matters

Package `upgrade_policy` for ONE is `"compatible"` because its dependencies (`SupraFramework`, `dora-interface`) are compatible; a dependent package cannot declare itself stricter than its deps. Functional immutability of ONE therefore comes from the deployer account, not from the package policy: no signer, no upgrade.

Publishing this key is the most direct, falsifiable way to communicate that the protocol will not be upgraded — not by the original developer, not by anyone.
