import { parseAbi } from "viem";

export const dexAbi = parseAbi([
  'function router() view returns (address)',
  'function dexFactory() view returns (address)',
  'function weth() view returns (address)',
  'function poolFor(address) view returns (address)',
  'function factory() view returns (address)',
  'function WETH() view returns (address)',
  'function getPair(address,address) view returns (address)',
  'function token0() view returns (address)',
  'function token1() view returns (address)',
  'function pool() view returns (address)',
  'function launchpad() view returns (address)',
  'function poolUnlocked() view returns (bool)',
  'function getReserves() view returns (uint112,uint112,uint32)',
  'function getAmountsOut(uint256,address[]) view returns (uint256[])',
  'function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256) payable',
  'function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)',
]);
export type DexRoute = { router: `0x${string}`; pool: `0x${string}`; wrapped: `0x${string}`; factory: `0x${string}` };
