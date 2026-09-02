// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestnetOnly} from "../script/TestnetOnly.sol";

contract Guarded is TestnetOnly {
    function run() external view testnetOnly returns (bool) {
        return true;
    }
}

/// @notice Weir is unaudited and never goes to a mainnet. This proves the deploy scripts cannot.
contract TestnetOnlyTest is Test {
    Guarded internal guarded = new Guarded();

    function test_theSupportedTestnetsAreAllowed() public {
        uint256[5] memory allowed = [uint256(11155111), 84532, 421614, 1301, 31337];

        for (uint256 i = 0; i < allowed.length; ++i) {
            vm.chainId(allowed[i]);
            assertTrue(guarded.run());
        }
    }

    function test_ethereumMainnetIsRefused() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(TestnetOnly.NotATestnet.selector, uint256(1)));
        guarded.run();
    }

    /// @dev The chains Weir would plausibly be pointed at by mistake, since its testnets share
    ///      their tooling and its PoolManager addresses are published side by side with theirs.
    function test_theOtherMainnetsWeirCouldBeAimedAtAreRefused() public {
        uint256[4] memory mainnets = [uint256(130), 8453, 42161, 137];

        for (uint256 i = 0; i < mainnets.length; ++i) {
            vm.chainId(mainnets[i]);
            vm.expectRevert(abi.encodeWithSelector(TestnetOnly.NotATestnet.selector, mainnets[i]));
            guarded.run();
        }
    }

    function testFuzz_anUnknownChainIsRefused(uint256 chainId) public {
        // `vm.chainId` only accepts values an EVM chain could actually report.
        chainId = bound(chainId, 1, type(uint64).max - 1);
        vm.assume(chainId != 11155111 && chainId != 84532 && chainId != 421614 && chainId != 1301 && chainId != 31337);

        vm.chainId(chainId);
        vm.expectRevert(abi.encodeWithSelector(TestnetOnly.NotATestnet.selector, chainId));
        guarded.run();
    }
}
