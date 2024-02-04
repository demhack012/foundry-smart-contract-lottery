// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {Raffle} from "../../src/Raffle.sol";
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract RaffleTest is Test {
    event EnteredRaffle(address indexed player);

    Raffle raffle;
    HelperConfig helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARING_USER_BALANCE = 10 ether;

    modifier raffleEntered() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        _;
    }

    modifier timePassed() {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    // modifier skipForked() {
    //     if (block.chainid != 31337) {
    //         return;
    //     }
    //     _;
    // }

    function setUp() external {
        DeployRaffle deployRaffle = new DeployRaffle();
        (raffle, helperConfig) = deployRaffle.run();
        (entranceFee, interval, vrfCoordinator, gasLane, subscriptionId, callbackGasLimit, link,) =
            helperConfig.activeNetworkConfig();
        vm.deal(PLAYER, STARING_USER_BALANCE);
    }

    function testRaffleInitializesInOpenState() external view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRaffleRevertsWhenYouDontSendEnoughEth() external {
        vm.prank(PLAYER);
        vm.expectRevert(Raffle.Raffle__NotEnooughEthSent.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordsPlayerWhenTheyEnter() external raffleEntered {
        // vm.prank(PLAYER);
        // raffle.enterRaffle{value: entranceFee}();
        assert(raffle.getPlayers(0) == PLAYER);
    }

    function testEmitsEventOnEntrance() external {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle));
        emit EnteredRaffle(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testCannotEnterRaffleWhenCalculatingWinner() external raffleEntered timePassed {
        // vm.prank(PLAYER);
        // raffle.enterRaffle{value: entranceFee}();
        // vm.warp(block.timestamp + interval + 1);
        // vm.roll(block.number + 1);
        raffle.performUpkeep("");
        vm.expectRevert(Raffle.Raffle__CalculatingWinner.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function testCheckUpkeepReturnsFalseWhenNoBalance() external timePassed {
        // vm.warp(block.timestamp + interval + 1);
        // vm.roll(block.number + 1);
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseWhenRaffleNotOpen() external raffleEntered timePassed {
        // vm.prank(PLAYER);
        // raffle.enterRaffle{value: entranceFee}();
        // vm.warp(block.timestamp + interval + 1);
        // vm.roll(block.number + 1);
        raffle.performUpkeep("");
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfEnoughTimeHasNotPassed() external raffleEntered {
        // vm.prank(PLAYER);
        // raffle.enterRaffle{value: entranceFee}();
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsTrueWhenAllConditionsMet() external raffleEntered timePassed {
        // vm.prank(PLAYER);
        // raffle.enterRaffle{value: entranceFee}();
        // vm.warp(block.timestamp + interval + 1);
        // vm.roll(block.number + 1);
        (bool upkeepNeeded,) = raffle.checkUpkeep("");
        assert(upkeepNeeded);
    }

    function testPerformUpkeepCanOnlyRunIfCheckUpkeepReturnsTrue() external raffleEntered timePassed {
        // vm.prank(PLAYER);
        // raffle.enterRaffle{value: entranceFee}();
        // vm.warp(block.timestamp + interval + 1);
        // vm.roll(block.number + 1);
        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepReturnsFalse() external {
        uint256 currentBalance = address(raffle).balance;
        uint256 numPlayers = raffle.getNumberOfPlayers();
        uint256 raffleState = uint256(raffle.getRaffleState());
        vm.expectRevert(
            abi.encodeWithSelector(Raffle.Raffle__UpkeepNotNeeded.selector, currentBalance, numPlayers, raffleState)
        );
        raffle.performUpkeep("");
    }

    function testPerformUpkeepUpdatesRaffleStaeAndEmitsRequestId() external raffleEntered timePassed {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        assert(raffleState == Raffle.RaffleState.CALCULATING_WINNER);
        assert(uint256(requestId) > 0);
        // console.log("request id: ", uint256(requestId));
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(uint256 randomRequestId)
        external
        raffleEntered
        timePassed
        skipWhenForking
    {
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(randomRequestId, address(raffle));
    }

    function testFulfillRandomWordsPicksAWinnerAndResetsAndSendMoney()
        external
        raffleEntered
        timePassed
        skipWhenForking
    {
        uint256 additionalEntrants = 5;
        uint256 startingIndex = 1;
        for (uint256 i = startingIndex; i < additionalEntrants + startingIndex; i++) {
            address player = address(uint160(i));
            hoax(player, STARING_USER_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }
        uint256 prize = (additionalEntrants + 1) * entranceFee;
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        uint256 previousTimeStamp = raffle.getLastTimeStamp();

        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
        assert(raffle.getNumberOfPlayers() == 0);
        assert(raffle.getLastTimeStamp() > previousTimeStamp);
        assert(raffle.getRecentWinner() != address(0));
        assert(raffle.getRecentWinner().balance == prize + STARING_USER_BALANCE - entranceFee);
    }
}
