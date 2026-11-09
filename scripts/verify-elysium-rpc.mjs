/** Read-only reproducible compatibility check. No wallet, signing, deployment or state-changing RPC methods. */
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { createPublicClient, http, parseAbi, getAddress, getCreate2Address, keccak256, encodePacked, toHex } from 'viem';
const endpoints = ['https://node.eleos.fun', 'https://rpc.hips.family'];
const blockNumber = BigInt(process.env.ELYSIUM_FORK_BLOCK || '2220982');
const router = getAddress('0xe783de89a7f0408687f051e3e6d0beb62719ebad');
const factory = getAddress('0xbbbcc62853a5fa27b93d6bab3e6f7ce841e25df2');
const wrapped = getAddress('0xbA876237B0F021A6c6D852d6c26E107997cC5E81');
const pairCodeHash = '0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f';
const abi = parseAbi(['function factory() view returns (address)','function WETH() view returns (address)','function allPairsLength() view returns (uint256)','function allPairs(uint256) view returns (address)','function getPair(address,address) view returns (address)','function token0() view returns (address)','function token1() view returns (address)']);
const results = [];
for (const endpoint of endpoints) {
  const client = createPublicClient({transport:http(endpoint,{timeout:30000,retryCount:1})});
  const chainId = await client.getChainId();
  assert.equal(chainId,99901,'Expected Kinetiq Elysium mainnet');
  const block = await client.getBlock({blockNumber});
  const read = (address,functionName,args=[]) => client.readContract({address,abi,functionName,args,blockNumber});
  assert.equal(getAddress(await read(router,'factory')),factory,'Router factory mismatch');
  assert.equal(getAddress(await read(router,'WETH')),wrapped,'Router wrapped HYPE mismatch');
  const count = await read(factory,'allPairsLength');
  assert(count > 0n && count <= 100n,'Factory pair count must be nonzero and bounded for this verifier');
  const code = {};
  async function recordCode(address) {
    const bytes = await client.getCode({address,blockNumber});
    assert(bytes && bytes !== '0x',`No code at ${address}`);
    code[address] = {bytes:(bytes.length-2)/2,keccak256:keccak256(bytes)};
  }
  await Promise.all([router,factory,wrapped].map(recordCode));
  const proxySlots = {};
  for (const label of ['implementation','admin','beacon']) {
    const slot = toHex(BigInt(keccak256(toHex(`eip1967.proxy.${label}`))) - 1n,{size:32});
    const value = await client.getStorageAt({address:wrapped,slot,blockNumber});
    proxySlots[label] = {slot,value};
    if (value && BigInt(value) !== 0n) {
      const target = getAddress(`0x${value.slice(-40)}`);
      await recordCode(target);
      proxySlots[label].address = target;
    }
  }
  assert.equal(code[factory].keccak256,'0xbab145d02e7005f0d84c6c1639d39b799b0ea16df99ebbdaf5a14d9da820b4e0','Factory differs from canonical npm artifact');
  const pairs = [];
  for (let i=0n;i<count;i++) {
    const pair = getAddress(await read(factory,'allPairs',[i]));
    const token0 = getAddress(await read(pair,'token0'));
    const token1 = getAddress(await read(pair,'token1'));
    assert(BigInt(token0) < BigInt(token1),'Token ordering invalid');
    const predicted = getCreate2Address({from:factory,salt:keccak256(encodePacked(['address','address'],[token0,token1])),bytecodeHash:pairCodeHash});
    assert.equal(getAddress(predicted),pair,'Pair CREATE2 hash mismatch');
    assert.equal(getAddress(await read(factory,'getPair',[token0,token1])),pair,'Factory pair mapping mismatch');
    assert.equal(getAddress(await read(factory,'getPair',[token1,token0])),pair,'Reverse factory pair mapping mismatch');
    await recordCode(pair);
    assert.equal(code[pair].keccak256,'0x5b83bdbcc56b2e630f2807bbadd2b0c21619108066b92a58de081261089e9ce5','Pair differs from canonical npm artifact');
    pairs.push({index:i.toString(),address:pair,token0,token1,predictedAddress:predicted,create2Proof:true,bidirectionalMapping:true});
  }
  const deploymentHash = '0xe7e8f22ca690aaef4d3546947d8e4d8bc608a34fd73af0a2b88eb28003d50d53';
  const receipt = await client.getTransactionReceipt({hash:deploymentHash});
  const deployment = await client.getTransaction({hash:deploymentHash});
  assert.equal(receipt.status,'success','Factory deployment receipt failed');
  assert.equal(getAddress(receipt.contractAddress),factory,'Deployment address mismatch');
  assert.equal(deployment.to,null,'Expected factory contract creation');
  assert.equal(deployment.blockHash,receipt.blockHash,'Deployment transaction/receipt block mismatch');
  const pendingNonce = await client.getTransactionCount({address:deployment.from,blockTag:'pending'});
  const logs = await client.getLogs({address:factory,fromBlock:receipt.blockNumber,toBlock:receipt.blockNumber+1999n});
  let wideRange;
  try {
    const wideLogs = await client.getLogs({address:factory,fromBlock:receipt.blockNumber,toBlock:receipt.blockNumber+9999n});
    wideRange = {accepted:true,count:wideLogs.length};
  } catch (error) {
    const details = String(error.details || error.shortMessage || error.message);
    wideRange = {accepted:false,error:details,reportedMaximumBlocks:/2000/.test(details)?2000:null};
  }
  const methods = {
    factoryDeployment:{hash:deploymentHash,from:deployment.from,contractAddress:receipt.contractAddress,blockNumber:receipt.blockNumber.toString(),blockHash:receipt.blockHash,status:receipt.status},
    pendingNonce:{address:deployment.from,blockTag:'pending',value:pendingNonce,note:'Live unpinned observation, may change between runs or providers.'},
    getLogs:{address:factory,narrowRange:{fromBlock:receipt.blockNumber.toString(),toBlock:(receipt.blockNumber+1999n).toString(),accepted:true,count:logs.length},wideRange:{fromBlock:receipt.blockNumber.toString(),toBlock:(receipt.blockNumber+9999n).toString(),...wideRange}},
  };
  results.push({endpoint,chainId,blockNumber:block.number.toString(),blockHash:block.hash,blockTimestamp:block.timestamp.toString(),router,factory,wrappedHype:wrapped,pairCodeHash,pairs,code,wrappedHypeProxySlots:proxySlots,methods});
}
const comparable = ({endpoint,methods,...result}) => result;
assert.deepEqual(comparable(results[0]),comparable(results[1]),'RPCs disagree on pinned state');
assert.deepEqual(results[0].methods.factoryDeployment,results[1].methods.factoryDeployment,'RPCs disagree on factory deployment receipt');
const output = {
  checkedAt:new Date().toISOString(),readOnly:true,matchAcrossEndpoints:true,
  scope:'Pinned-state RPC agreement and V2 CREATE2 compatibility, not operator independence, official endorsement, bytecode provenance or security audit.',
  canonicalArtifactComparison:{package:'@uniswap/v2-core@1.0.1',registryTarball:'https://registry.npmjs.org/@uniswap/v2-core/-/v2-core-1.0.1.tgz',tarballSha1:'af8f508bf183204779938969e2e54043e147d425',factoryRuntimeExactMatch:true,pairRuntimeExactMatch:true,pairCreationCodeHashExactMatch:true,routerRuntimeCompared:false},
  wrappedHypeCaveat:'Nonzero EIP-1967 implementation/admin slots indicate a proxy trust/upgrade surface. Matching current bytecode is not a guarantee of immutable future behavior or proof of admin ownership.',
  sources:{addresses:'https://titanlocker.com/docs/uniswap-on-elysium',pairInitCodeHash:'https://raw.githubusercontent.com/Uniswap/v2-periphery/master/contracts/libraries/UniswapV2Library.sol',officialNetwork:'https://elysium.kinetiq.xyz/docs/connecting-to-elysium'},
  results,
};
writeFileSync('docs/elysium-verification.json',JSON.stringify(output,null,2)+'\n');
console.log(`Verified both RPCs at Elysium block ${blockNumber}: identical block and code hashes; ${results[0].pairs.length} pairs proven. Saved docs/elysium-verification.json.`);
