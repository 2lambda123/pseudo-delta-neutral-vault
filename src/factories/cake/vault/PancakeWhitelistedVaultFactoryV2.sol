pragma solidity ^0.8.0;

import '@rivera/factories/interfaces/IRiveraVaultFactory.sol';
import '@rivera/strategies/common/interfaces/IStrategy.sol';
import '@rivera/vaults/RiveraAutoCompoundingVaultV2Whitelisted.sol';
import '../PancakeStratFactoryV2.sol';
import '../PancakeVaultCreationStruct.sol';

contract PancakeWhitelistedVaultFactoryV2 is IRiveraVaultFactory {

    address[] public allVaults;

    ///@notice fixed params that are required to deploy the pool
    address public chef;
    address public router;
    address public NonfungiblePositionManager;
    address public manager;
    address public stratFactory;
    VaultType public immutable vaultType = VaultType.WHITELISTED;

    constructor(address _chef, address _router, address _NonfungiblePositionManager, address _stratFactory) {
        chef = _chef;
        router = _router;
        NonfungiblePositionManager = _NonfungiblePositionManager;
        stratFactory = _stratFactory;
        manager = msg.sender;
    }

    function createVault(PancakeVaultParams memory createVaultParams) external returns (address vaultAddress) {
        RiveraAutoCompoundingVaultV2Whitelisted vault = new RiveraAutoCompoundingVaultV2Whitelisted(createVaultParams.asset, createVaultParams.tokenName, createVaultParams.tokenSymbol, 
        createVaultParams.approvalDelay, createVaultParams.totalTvlCap);
        vaultAddress = address(vault);
        address stratAddress = PancakeStratFactoryV2(stratFactory).createStrat(createVaultParams, vaultAddress, msg.sender, manager, router, NonfungiblePositionManager, chef);
        vault.transferOwnership(msg.sender);
        vault.init(IStrategy(stratAddress));
        allVaults.push(vaultAddress);
        emit VaultCreated(msg.sender, createVaultParams.stake,  vaultAddress);
    }

    function listAllVaults() external view returns (address[] memory) {
        return allVaults;
    }

}