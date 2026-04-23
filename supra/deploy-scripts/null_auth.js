// Final step: rotate deployer auth_key to all zeros.
// POINT OF NO RETURN. After this, deployer cannot sign any tx on this chain ever again.
// The contract's upgrade_policy remains "compatible" — functional immutability comes from
// the fact that no signer can call publish_package_txn for the deployer address. The
// contract itself is technically still upgradeable IF a signer existed, which it doesn't.
// Protocol remains fully functional via permissionless public entry fns (no signer needed).
const { SupraClient, SupraAccount, BCS } = require('supra-l1-sdk');

const RPC = process.env.SUPRA_RPC || 'https://rpc-testnet.supra.com';
const PRIVATE_KEY_HEX = process.env.DEPLOYER_KEY;
if (!PRIVATE_KEY_HEX) { console.error('DEPLOYER_KEY env var required'); process.exit(1); }

(async () => {
  const client = await SupraClient.init(RPC);
  const acc = new SupraAccount(Uint8Array.from(Buffer.from(PRIVATE_KEY_HEX.slice(2), 'hex')));
  console.log(`deployer: ${acc.address().toString()}`);

  const info = await client.getAccountInfo(acc.address());
  console.log(`current auth_key: ${info.authentication_key}`);
  console.log(`sequence_number:  ${info.sequence_number}`);

  const bal = await client.getAccountSupraCoinBalance(acc.address());
  console.log(`balance: ${bal} raw (${Number(bal)/1e8} SUPRA)`);

  // Construct tx: 0x1::account::rotate_authentication_key_call(signer, vector<u8>(32 zero bytes))
  const zeroAuth = new Uint8Array(32);  // all zeros
  const tx = await client.createSerializedRawTxObject(
    acc.address(), info.sequence_number,
    '0x1', 'account', 'rotate_authentication_key_call',
    [],
    [BCS.bcsSerializeBytes(zeroAuth)],
    { maxGas: 5000n }
  );

  console.log('\n⚠️  Submitting null_auth tx — IRREVERSIBLE');
  const r = await client.sendTxUsingSerializedRawTransaction(acc, tx,
    { enableTransactionWaitAndSimulationArgs: { enableWaitForTransaction: true } });
  console.log(`tx: ${r.txHash} — ${r.result}`);

  await new Promise(r => setTimeout(r, 3000));

  const d = await client.getTransactionDetail(acc.address(), r.txHash);
  console.log(`status: ${d?.status}, vm: ${d?.vm_status}, gas: ${d?.gasUsed}`);

  // Verify auth_key is now 0x0...0
  const postInfo = await client.getAccountInfo(acc.address());
  console.log(`\npost auth_key: ${postInfo.authentication_key}`);
  console.log(`post seq:      ${postInfo.sequence_number}`);

  if (postInfo.authentication_key === '0x0000000000000000000000000000000000000000000000000000000000000000') {
    console.log('\n✅ Deployer auth_key is now 0x0 — deployer is permanently unsignable.');
    console.log('   The ONE contract itself stays at upgrade_policy = "compatible".');
    console.log('   Functional immutability: no signer exists → no upgrade can ever be published.');
    console.log('   Protocol runs autonomously via permissionless public entries (no signer needed).');
  } else {
    console.log('\n⚠️  auth_key not zero — check tx status');
  }
})().catch(e => {
  console.error('ERROR:', e.message);
  if (e.response?.data) console.error('resp:', JSON.stringify(e.response.data).slice(0, 500));
});
