// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// The parts of IdentityMD's on-chain Intake this project uses (docs: imd.fun/docs, "Pay on chain").
/// One call pays 0.5 IMD and asks the agent swarm a question; the signed answer comes back to `callback`.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        returns (bytes32 requestId);
}

/// The answer the swarm signs (EIP-712, domain "IdentityMD Oracle" version "2").
/// Field order is the one the oracle signs; the callback selector 0x510379c7 confirms it.
library OracleAttestation {
    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    bytes32 internal constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    function hash(Attestation calldata a) internal pure returns (bytes32) {
        // two halves, so the encoder stays inside the stack limit
        bytes memory head = abi.encode(TYPEHASH, a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure, a.fromBlock);
        bytes memory tail = abi.encode(a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt);
        return keccak256(bytes.concat(head, tail));
    }
}
