// Bootstrap ONE on Aptos testnet:
// 1. Fetch fresh APT/USD VAA from Pyth hermes
// 2. Submit pyth::update_price_feeds tx
// 3. Submit ONE::open_trove tx
// 4. Submit ONE::sp_deposit tx
const { Aptos, AptosConfig, Network, Account, Ed25519PrivateKey } = require('@aptos-labs/ts-sdk');

const NETWORK = process.env.APTOS_NETWORK || 'testnet';
const PRIVATE_KEY_HEX = process.env.DEPLOYER_KEY;
if (!PRIVATE_KEY_HEX) { console.error('DEPLOYER_KEY env var required'); process.exit(1); }
const ONE_ADDR = process.env.ONE_ADDR;
if (!ONE_ADDR) { console.error('ONE_ADDR env var required'); process.exit(1); }
const PYTH_ADDR = '0x7e783b349d3e89cf5931af376ebeadbfab855b3fa239b7ada8f5a92fbea6b387';
const APT_USD_FEED = '0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5';
const APT_AMT = BigInt(process.env.APT_AMT || 220_000_000n);       // 2.2 APT
const DEBT    = BigInt(process.env.DEBT    || 100_000_000n);       // 1 ONE
const SP_AMT  = BigInt(process.env.SP_AMT  || 99_000_000n);        // 0.99 ONE

(async () => {
  const config = new AptosConfig({ network: NETWORK === 'mainnet' ? Network.MAINNET : Network.TESTNET });
  const aptos = new Aptos(config);
  const pk = new Ed25519PrivateKey(PRIVATE_KEY_HEX);
  const account = Account.fromPrivateKey({ privateKey: pk });
  console.log(`signer: ${account.accountAddress.toString()}`);

  // Step 1: Fetch VAA
  console.log('\n=== 1. Fetch VAA ===');
  const vaaResp = await fetch(`https://hermes.pyth.network/api/latest_vaas?ids[]=${APT_USD_FEED}`);
  const vaaB64Arr = await vaaResp.json();
  const vaaBytesArr = vaaB64Arr.map(b64 => Uint8Array.from(Buffer.from(b64, 'base64')));
  console.log(`  VAA count: ${vaaBytesArr.length}, first len: ${vaaBytesArr[0].length} bytes`);

  // Step 2: update_price_feeds_with_funder (signer pays fee directly, no Coin construction needed)
  console.log('\n=== 2. pyth::update_price_feeds_with_funder ===');
  const updateTx = await aptos.transaction.build.simple({
    sender: account.accountAddress,
    data: {
      function: `${PYTH_ADDR}::pyth::update_price_feeds_with_funder`,
      functionArguments: [vaaBytesArr.map(v => Array.from(v))],
    },
  });
  const updateTxResp = await aptos.signAndSubmitTransaction({ signer: account, transaction: updateTx });
  console.log(`  tx: ${updateTxResp.hash}`);
  await aptos.waitForTransaction({ transactionHash: updateTxResp.hash });
  console.log('  ✓ Pyth price updated');

  // Step 3: ONE::open_trove
  console.log('\n=== 3. ONE::open_trove ===');
  const openTx = await aptos.transaction.build.simple({
    sender: account.accountAddress,
    data: {
      function: `${ONE_ADDR}::ONE::open_trove`,
      functionArguments: [APT_AMT.toString(), DEBT.toString()],
    },
  });
  const openResp = await aptos.signAndSubmitTransaction({ signer: account, transaction: openTx });
  console.log(`  tx: ${openResp.hash}`);
  await aptos.waitForTransaction({ transactionHash: openResp.hash });
  console.log(`  ✓ trove opened: ${APT_AMT} raw APT coll / ${DEBT} raw ONE debt`);

  // Step 4: ONE::sp_deposit
  if (SP_AMT > 0n) {
    console.log('\n=== 4. ONE::sp_deposit ===');
    const spTx = await aptos.transaction.build.simple({
      sender: account.accountAddress,
      data: {
        function: `${ONE_ADDR}::ONE::sp_deposit`,
        functionArguments: [SP_AMT.toString()],
      },
    });
    const spResp = await aptos.signAndSubmitTransaction({ signer: account, transaction: spTx });
    console.log(`  tx: ${spResp.hash}`);
    await aptos.waitForTransaction({ transactionHash: spResp.hash });
    console.log(`  ✓ sp_deposit: ${SP_AMT} raw ONE`);
  }

  // Final state
  console.log('\n=== final state ===');
  const totals = await aptos.view({
    payload: { function: `${ONE_ADDR}::ONE::totals`, functionArguments: [] },
  });
  console.log(`  totals: debt=${totals[0]}, sp=${totals[1]}, P=${totals[2]}, r_one=${totals[3]}, r_supra=${totals[4]}`);
  const trove = await aptos.view({
    payload: { function: `${ONE_ADDR}::ONE::trove_of`, functionArguments: [account.accountAddress.toString()] },
  });
  console.log(`  trove: coll=${trove[0]}, debt=${trove[1]}`);
})().catch(e => {
  console.error('\nERROR:', e.message || e);
  process.exit(1);
});
