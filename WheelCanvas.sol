// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// Minimal read-only view of SqueekCore V3 (Sepolia proxy, see the Squeekchain deployment record).
interface ISqueekCore {
    struct CoreState {
        uint64 settledThroughRound;
        uint64 cumulativeWork;
        uint96 cumulativeBlockUnits;
        uint64 blockHeight;
        uint96 blockProgress;
        uint32 workPerThousandBlocks;
        uint256 authorizationNonce;
        bool paused;
    }

    struct LedgerPosition {
        uint64 cumulativeWork;
        uint96 cumulativeBlockUnits;
        uint32 workPerThousandBlocks;
    }

    struct RoundCheckpoint {
        uint64 roundId;
        uint64 cumulativeWork;
        uint96 cumulativeBlockUnits;
        uint32 workPerThousandBlocks;
        bytes32 dataHash;
    }

    struct RoundPage {
        uint64 certifiedThroughRound;
        LedgerPosition start;
        LedgerPosition end;
        RoundCheckpoint[] rounds;
    }

    function state() external view returns (CoreState memory);

    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maxRecords)
        external
        view
        returns (RoundPage memory);
}

/// @title Wheel Canvas
/// @notice One NFT image per "day" (144 SqueekCore rounds of 10 minutes). The first mint of a day
///         snapshots that day's work per round from SqueekCore; the SVG is then drawn on-chain from
///         the snapshot, so later SqueekCore upgrades cannot change a canvas that already exists.
/// @dev Unofficial community project, not affiliated with Squeekchain. Testnet only, unaudited.
contract WheelCanvas is ERC721 {
    uint64 public constant ROUNDS_PER_DAY = 144;
    uint256 public constant MAX_DAY = 1_000_000;

    ISqueekCore public immutable core;

    struct Canvas {
        bool captured;
        uint16 peak; // highest work in a single round that day
        uint16 active; // rounds with nonzero work
        uint32 total; // total work that day
        uint16[144] work; // work per round, index 0 = first round of the day
    }

    mapping(uint256 => Canvas) private canvases;
    mapping(uint256 => mapping(address => bool)) public minted; // day => owner => has minted
    mapping(uint256 => uint256) public tokenDay;
    uint256 public nextId;

    event Captured(uint256 indexed day, uint32 totalWork, uint16 peak, uint16 activeRounds);

    error DayOutOfRange();
    error DayNotSettled();
    error AlreadyMinted();
    error BadRound();
    error WorkTooLarge();
    error NoProgress();

    constructor(address squeekCore) ERC721("Wheel Canvas", "WHEEL") {
        core = ISqueekCore(squeekCore);
    }

    // ------------------------------------------------------------------ views

    /// Number of fully settled days; days 0 .. mintableDays()-1 can be minted.
    function mintableDays() public view returns (uint256) {
        return core.state().settledThroughRound / ROUNDS_PER_DAY;
    }

    function isCaptured(uint256 day) external view returns (bool) {
        return canvases[day].captured;
    }

    function summary(uint256 day) external view returns (bool captured, uint32 total, uint16 peak, uint16 active) {
        Canvas storage c = canvases[day];
        return (c.captured, c.total, c.peak, c.active);
    }

    function workOf(uint256 day) external view returns (uint16[144] memory) {
        return canvases[day].work;
    }

    // ------------------------------------------------------------------- mint

    /// Mint the canvas of `day` (0-based, counted from SqueekCore round 1). One per address per day.
    function mint(uint256 day) external returns (uint256 id) {
        if (day > MAX_DAY) revert DayOutOfRange();
        if (minted[day][msg.sender]) revert AlreadyMinted();
        if (!canvases[day].captured) _capture(day);

        minted[day][msg.sender] = true;
        id = ++nextId;
        tokenDay[id] = day;
        _mint(msg.sender, id);
    }

    function _capture(uint256 day) internal {
        uint64 first = uint64(day) * ROUNDS_PER_DAY; // rounds first+1 .. first+144 belong to this day
        uint64 last = first + ROUNDS_PER_DAY;
        if (core.state().settledThroughRound < last) revert DayNotSettled();

        Canvas storage c = canvases[day];
        uint64 prev = core.roundPage(first, first, 0).end.cumulativeWork;
        uint64 cursor = first;
        uint16 peak;
        uint16 active;
        uint32 total;

        while (cursor < last) {
            ISqueekCore.RoundPage memory p = core.roundPage(cursor, last, 16);
            uint256 n = p.rounds.length;
            for (uint256 i; i < n; ++i) {
                ISqueekCore.RoundCheckpoint memory r = p.rounds[i];
                if (r.roundId <= first || r.roundId > last) revert BadRound();
                uint64 w = r.cumulativeWork - prev;
                prev = r.cumulativeWork;
                if (w > type(uint16).max) revert WorkTooLarge();
                c.work[r.roundId - first - 1] = uint16(w);
                total += uint32(w);
                if (w > 0) ++active;
                if (w > peak) peak = uint16(w);
            }
            if (p.certifiedThroughRound <= cursor) revert NoProgress();
            cursor = p.certifiedThroughRound;
        }

        c.captured = true;
        c.peak = peak;
        c.active = active;
        c.total = total;
        emit Captured(day, total, peak, active);
    }

    // --------------------------------------------------------------- metadata

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        uint256 day = tokenDay[id];
        Canvas storage c = canvases[day];

        string memory json = string.concat(
            '{"name":"Wheel Canvas - Day ',
            Strings.toString(day),
            '","description":"One day of Squeektoshi on the wheel, painted on-chain from SqueekCore round data. Unofficial community project.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(c))),
            '","attributes":[{"trait_type":"Day","value":',
            Strings.toString(day),
            '},{"trait_type":"Total work","value":',
            Strings.toString(c.total),
            '},{"trait_type":"Active rounds","value":',
            Strings.toString(c.active),
            '},{"trait_type":"Peak round work","value":',
            Strings.toString(c.peak),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// 12 x 12 grid, one dot per round, read left to right and top to bottom. Brighter and bigger = more work.
    function _svg(Canvas storage c) internal view returns (string memory) {
        bytes memory out = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 240"><rect width="240" height="240" fill="#0b0b0d"/>'
        );
        uint256 peak = c.peak == 0 ? 1 : c.peak;
        for (uint256 i; i < 144; ++i) {
            uint256 w = c.work[i];
            uint256 pct = 8 + (w * 92) / peak; // 8..100 (quiet rounds stay faintly visible)
            uint256 r = 3 + (w * 6) / peak; // 3..9
            out = abi.encodePacked(
                out,
                '<circle cx="',
                Strings.toString(10 + (i % 12) * 20),
                '" cy="',
                Strings.toString(10 + (i / 12) * 20),
                '" r="',
                Strings.toString(r),
                '" fill="#ffb347" fill-opacity="',
                _opacity(pct),
                '"/>'
            );
        }
        return string(abi.encodePacked(out, "</svg>"));
    }

    function _opacity(uint256 p) internal pure returns (string memory) {
        if (p >= 100) return "1";
        return string.concat(p < 10 ? "0.0" : "0.", Strings.toString(p));
    }
}
