import { dustAbi, addresses } from "@neverland-money/tokenomics-core";
import {
  Dust__factory,
  type Dust,
} from "@neverland-money/tokenomics-core/types";
import { Dust__factory as NestedDustFactory } from "@neverland-money/tokenomics-core/types/factories/src/tokens/Dust__factory";
import type { Dust as NestedDust } from "@neverland-money/tokenomics-core/types/src/tokens/Dust";

const token: Dust = Dust__factory.connect(addresses.addresses.Dust);
const address: string = addresses.addresses.Dust;
const nestedToken: NestedDust = NestedDustFactory.connect(address);
void token.initialize.populateTransaction(address, 0n);
void nestedToken.transfer.populateTransaction(address, 1n);
void dustAbi;
