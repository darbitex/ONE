// Deposit all deployer ONE to SP as permanent seed (locked post-null-auth).
// Run AFTER bootstrap + BEFORE null_auth. The deployer's 0.99 ONE from genesis mint
// goes into SP as dead-weight base capital that can absorb future liquidations.
const { SupraClient, SupraAccount, BCS, TxnBuilderTypes } = require('supra-l1-sdk');

const RPC = process.env.SUPRA_RPC || 'https://rpc-testnet.supra.com';
const PRIVATE_KEY_HEX = process.env.DEPLOYER_KEY;
if (!PRIVATE_KEY_HEX) { console.error('DEPLOYER_KEY env var required'); process.exit(1); }
// Module address (package was published here). Defaults to deployer address (single-signer case).
const DEPLOYER = process.env.MODULE_ADDR;  // computed from pubkey below if unset
const AMOUNT = BigInt(process.env.AMOUNT || 99_000_000n); // default 0.99 ONE

(async () => {
  const client = await SupraClient.init(RPC);
  const account = new SupraAccount(
    Uint8Array.from(Buffer.from(PRIVATE_KEY_HEX.slice(2), 'hex'))
  );
  const moduleAddr = DEPLOYER || account.address().toString();
  const seq = (await client.getAccountInfo(account.address())).sequence_number;
  console.log(`deployer: ${account.address().toString()}, seq: ${seq}`);
  console.log(`module at: ${moduleAddr}`);
  console.log(`depositing: ${AMOUNT} raw (${Number(AMOUNT)/1e8} ONE) to SP`);

  const serializedTx = await client.createSerializedRawTxObject(
    account.address(),
    seq,
    moduleAddr,                    // module address (= deployer in single-signer case)
    'ONE',                         // module name
    'sp_deposit',                  // function name
    [],                            // type args
    [BCS.bcsSerializeUint64(AMOUNT)], // args: amt
    { maxGas: 200000n }
  );

  console.log(`Depositing ${AMOUNT} raw (0.99 ONE) to SP...`);
  const result = await client.sendTxUsingSerializedRawTransaction(
    account,
    serializedTx,
    { enableTransactionWaitAndSimulationArgs: { enableWaitForTransaction: true } }
  );
  console.log(`tx hash: ${result.txHash}`);
  console.log(`result:  ${result.result}`);

  const detail = await client.getTransactionDetail(account.address(), result.txHash);
  if (detail) {
    console.log(`status: ${detail.status}, gas: ${detail.gasUsed}, vm: ${detail.vm_status}`);
  }
})().catch(e => {
  console.error('ERROR:', e.message);
  if (e.response?.data) console.error('response:', JSON.stringify(e.response.data).slice(0, 500));
  process.exit(1);
});
