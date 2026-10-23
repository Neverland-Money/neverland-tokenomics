import assert from "node:assert/strict";
import { dustAbi, addresses } from "@neverland-money/tokenomics-core";
import { Dust__factory } from "@neverland-money/tokenomics-core/types";
import { Dust__factory as NestedDustFactory } from "@neverland-money/tokenomics-core/types/factories/src/tokens/Dust__factory";
import addressBook from "@neverland-money/tokenomics-core/addresses" with { type: "json" };
import artifact from "@neverland-money/tokenomics-core/artifacts/src/tokens/Dust.sol/Dust.json" with { type: "json" };

assert.equal(NestedDustFactory, Dust__factory);
assert.deepEqual(addressBook, addresses);
assert.deepEqual(dustAbi, artifact.abi);

assert(
  dustAbi.some(
    (entry) => entry.type === "function" && entry.name === "transfer"
  )
);
assert.equal(
  Dust__factory.connect(addresses.addresses.Dust).target,
  addresses.addresses.Dust
);
