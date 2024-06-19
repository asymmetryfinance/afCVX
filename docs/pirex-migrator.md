## Goal

The Pirex Migrator helps Llama Airforce (https://llama.airforce/#/union/pounders) uCVX users or Pirex (https://pirex.io/vaults/pxcvx) pxCVX or upxCVX users in migrating into Asymmetry's afCVX system.

## Methodology

### uCVX Instant Migration

uCVX holders can call the `PirexMigrator.migrate()` method with the following arguments to (1) redeem their uCVX into pxCVX, (2) use Pirex LP to swap the pxCVX to CVX, and (3) deposit the CVX for afCVX:

- uint256 amount - amount of uCVX
- uint256 minSwapReceived - minimum amount of CVX to receive from the swap
- uint256 lockIndex - not used. can be set to 0
- address receiver - receiver of afCVX tokens
- bool isUnionized - set to true
- bool isSwap - set to true

the method will return the amount of afCVX sent to the receiver.

### pxCVX Instant Migration

pxCVX holders can call the `PirexMigrator.migrate()` method with the following arguments to (1) swap their pxCVX to CVX, and (2) deposit the CVX for afCVX:

- uint256 amount - amount of pxCVX
- uint256 minSwapReceived - minimum amount of CVX to receive from the swap
- uint256 lockIndex - not used. can be set to 0
- address receiver - receiver of afCVX tokens
- bool isUnionized - set to false
- bool isSwap - set to true

the method will return the amount of afCVX sent to the receiver.

### uCVX Deferred Migration

uCVX holders can call the `PirexMigrator.migrate()` method with the following arguments to (1) redeem their uCVX into pxCVX, and (2) initiate the redemption of the pxCVX at a specific unlock time:

- uint256 amount - amount of uCVX
- uint256 minSwapReceived - not used. can be set to 0
- uint256 lockIndex - index of the Pirex lock to redeem the pxCVX at
- address receiver - receiver of credited upxCVX tokens
- bool isUnionized - set to true
- bool isSwap - set to false

the method will return the amount of upxCVX credited to the receiver.

### pxCVX Deferred Migration

pxCVX holders can call the `PirexMigrator.migrate()` method with the following arguments to (1) initiate the redemption of the pxCVX at a specific unlock time:

- uint256 amount - amount of pxCVX
- uint256 minSwapReceived - not used. can be set to 0
- uint256 lockIndex - index of the Pirex lock to redeem the pxCVX at
- address receiver - receiver of credited upxCVX tokens
- bool isUnionized - set to false
- bool isSwap - set to false

the method will return the amount of upxCVX credited to the receiver.

### upxCVX Migration

upxCVX holders can call the `PirexMigrator.migrate()` method with the following arguments to (1) redeem their upxCVX into CVX, and (2) deposit the CVX for afCVX:

- uint256[] unlockTimes - upxCVX unlock timestamps
- uint256[] amounts - upxCVX amounts
- address receiver - receiver of afCVX tokens

the method will return the amount of afCVX sent to the receiver.

### Redemption of credited upxCVX

anyone can call the `PirexMigrator.redeem()` or `PirexMigrator.multiRedeem()` method with the following arguments to redeem the credited upxCVX for CVX and deposit into afCVX for a specific unlock time and user:

- uint256 unlockTime - CVX unlock timestamp
- address for - the address to redeem for

the method will return the amount of afCVX sent to the receiver.

## Notes

- There are no privileged roles in the contract.
- The contract is not upgradeable and entirely immutable.