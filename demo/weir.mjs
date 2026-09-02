// Drives a sealed-bid epoch against a deployed Weir stack.
//
// A sealed bid cannot be produced from Solidity. CoFHE only accepts a ciphertext that its
// verifier has signed, and that signature comes from encrypting client-side — so the bidding
// half of the demo lives here rather than in a forge script.
//
//   node weir.mjs status
//   node weir.mjs deposit 0.02
//   node weir.mjs bid 0.004 0.01     # bid 0.004 ETH, committing 0.01 as collateral
//   node weir.mjs close <epoch>
//   node weir.mjs settle <epoch>
//   node weir.mjs release <epoch>
//
// Env: RPC_URL, PRIVATE_KEY, WEIR_AUCTION, POOL_ID

import { createRequire } from "node:module";
import { ethers } from "ethers";

// cofhejs 0.3.1 ships an .mjs bundle that still calls `require` for node builtins, so importing
// it as ESM throws. The CommonJS build is fine; pull it in through a require shim.
const { cofhejs, Encryptable } = createRequire(import.meta.url)("cofhejs/node");

const AUCTION_ABI = [
  "function deposit() payable",
  "function withdraw(uint256 amount)",
  "function bidSealed(bytes32 poolId, uint256 collateralCap, (uint256,uint8,uint8,bytes) sealedBid)",
  "function closeBidding(bytes32 poolId, uint256 epoch)",
  "function settleEpoch(bytes32 poolId, uint256 epoch)",
  "function releaseCollateral(bytes32 poolId, uint256 epoch) returns (uint256)",
  "function currentEpoch(bytes32 poolId) view returns (uint256)",
  "function biddingEpoch(bytes32 poolId) view returns (uint256)",
  "function epochStartBlock(bytes32 poolId, uint256 epoch) view returns (uint256)",
  "function winnerOf(bytes32 poolId, uint256 epoch) view returns (address)",
  "function reservePrice(bytes32 poolId) view returns (uint256)",
  "function collateral(address bidder) view returns (uint256)",
  "function freeCollateral(address bidder) view returns (uint256)",
  "function lockOf(bytes32 poolId, uint256 epoch, address bidder) view returns (uint256)",
  "function settlementReady(bytes32 poolId, uint256 epoch) view returns (bool)",
  "function biddingClosable(bytes32 poolId, uint256 epoch) view returns (bool)",
  "function hasBids(bytes32 poolId, uint256 epoch) view returns (bool)",
  "function epochState(bytes32 poolId, uint256 epoch) view returns ((uint256,uint256,bool,bool,address,uint256))",
];

function need(name) {
  const value = process.env[name];
  if (!value) throw new Error(`missing env ${name}`);
  return value;
}

async function connect() {
  const provider = new ethers.JsonRpcProvider(need("RPC_URL"));
  const signer = new ethers.Wallet(need("PRIVATE_KEY"), provider);
  const auction = new ethers.Contract(need("WEIR_AUCTION"), AUCTION_ABI, signer);
  return { provider, signer, auction, poolId: need("POOL_ID") };
}

async function send(label, promise) {
  const tx = await promise;
  process.stdout.write(`${label} ... `);
  const receipt = await tx.wait();
  console.log(`${receipt.status === 1 ? "ok" : "FAILED"}  ${tx.hash}`);
  return receipt;
}

async function status({ provider, signer, auction, poolId }) {
  const [block, current, bidding, reserve, held, free] = await Promise.all([
    provider.getBlockNumber(),
    auction.currentEpoch(poolId),
    auction.biddingEpoch(poolId),
    auction.reservePrice(poolId),
    auction.collateral(signer.address),
    auction.freeCollateral(signer.address),
  ]);

  console.log(`block            ${block}`);
  console.log(`current epoch    ${current}`);
  console.log(`bidding for      ${bidding}`);
  console.log(`reserve          ${ethers.formatEther(reserve)} ETH`);
  console.log(`collateral       ${ethers.formatEther(held)} ETH (${ethers.formatEther(free)} free)`);

  // The two epochs either side of the current one are the ones with anything to show.
  for (let e = current; e <= bidding; e++) {
    const [state, ready] = await Promise.all([auction.epochState(poolId, e), auction.settlementReady(poolId, e)]);
    const [, , closed, settled, winner, winningBid] = state;
    const outcome = settled
      ? winner === ethers.ZeroAddress
        ? "settled, no winner"
        : `won by ${winner} for ${ethers.formatEther(winningBid)} ETH`
      : closed
        ? ready
          ? "closed, decryption ready"
          : "closed, awaiting decryption"
        : "open";
    console.log(`  epoch ${e}  ${outcome}`);
  }
}

async function bid({ provider, signer, auction, poolId }, bidEth, capEth) {
  const bidWei = ethers.parseEther(bidEth);
  const capWei = ethers.parseEther(capEth);

  const free = await auction.freeCollateral(signer.address);
  if (free < capWei) {
    throw new Error(`only ${ethers.formatEther(free)} ETH free; deposit more before committing ${capEth}`);
  }

  console.log("initialising cofhejs against the live coprocessor ...");
  const init = await cofhejs.initializeWithEthers({
    ethersProvider: provider,
    ethersSigner: signer,
    environment: "TESTNET",
  });
  if (!init.success) throw new Error(`cofhejs init failed: ${JSON.stringify(init.error)}`);

  // This is the step that has no Solidity equivalent: the value is encrypted here and the
  // coprocessor's verifier signs it, so the chain never sees the number.
  const encrypted = await cofhejs.encrypt([Encryptable.uint128(bidWei)]);
  if (!encrypted.success) throw new Error(`encrypt failed: ${JSON.stringify(encrypted.error)}`);

  const [sealed] = encrypted.data;
  console.log(`sealed ${bidEth} ETH as ciphertext ${sealed.ctHash}`);

  const epoch = await auction.biddingEpoch(poolId);
  await send(
    `bidSealed for epoch ${epoch}`,
    auction.bidSealed(poolId, capWei, [sealed.ctHash, sealed.securityZone, sealed.utype, sealed.signature]),
  );
  console.log("the bid value is not recoverable from this transaction");
}

const [command, ...args] = process.argv.slice(2);

const ctx = await connect();

switch (command) {
  case "status":
    await status(ctx);
    break;
  case "deposit":
    await send(`deposit ${args[0]} ETH`, ctx.auction.deposit({ value: ethers.parseEther(args[0]) }));
    break;
  case "bid":
    await bid(ctx, args[0], args[1] ?? args[0]);
    break;
  case "close":
    await send(`closeBidding epoch ${args[0]}`, ctx.auction.closeBidding(ctx.poolId, args[0]));
    break;
  case "settle":
    await send(`settleEpoch epoch ${args[0]}`, ctx.auction.settleEpoch(ctx.poolId, args[0]));
    console.log(`winner: ${await ctx.auction.winnerOf(ctx.poolId, args[0])}`);
    break;
  case "release":
    await send(`releaseCollateral epoch ${args[0]}`, ctx.auction.releaseCollateral(ctx.poolId, args[0]));
    break;
  default:
    console.log("commands: status | deposit <eth> | bid <eth> [cap] | close <epoch> | settle <epoch> | release <epoch>");
    process.exit(1);
}
