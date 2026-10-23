import { dustAbi, addresses } from "@neverland-money/tokenomics-core";
import {
  Dust__factory,
  type Dust,
} from "@neverland-money/tokenomics-core/types";
import { Dust__factory as NestedDustFactory } from "@neverland-money/tokenomics-core/types/factories/src/tokens/Dust__factory";
import type { Dust as NestedDust } from "@neverland-money/tokenomics-core/types/src/tokens/Dust";
import addressBook = require("@neverland-money/tokenomics-core/addresses");

const token: Dust = Dust__factory.connect(addresses.addresses.Dust);
const address: string = addresses.addresses.Dust;
const nestedToken: NestedDust = NestedDustFactory.connect(address);
void token.initialize.populateTransaction(address, 0n);
void nestedToken.transfer.populateTransaction(address, 1n);
void dustAbi;

const jsonChainId: number = addressBook.chainId;
const jsonAddress: string = addressBook.addresses.Dust;
// @ts-expect-error JSON chain IDs are numbers, not strings.
const invalidChainId: string = addressBook.chainId;
// @ts-expect-error The address book has a concrete schema, not an any type.
void addressBook.addresses.UnknownContract;
void jsonChainId;
void jsonAddress;
void invalidChainId;
