// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/// @title The questions LastSeenRegistry asks the IdentityMD swarm, as the swarm reads them
/// @notice Stateless text building, kept out of the registry so its runtime stays under EIP-170 with the
///         project's own build settings (no optimizer). The registry creates one in its constructor and
///         calls it with STATICCALL; nothing here reads or writes state.
///
/// A case verdict and an on-chain hop use an absolute block window, so their `questionHash` is known when
/// they are asked: the body is built in the oracle's canonical member order (keys sorted: answerType,
/// chainId, definitions, question, v, window; chain evidence is the default and is left out, as the
/// protocol's `OracleQuestion` does), and the hash is keccak-256 of those members closed with `}`. The
/// registry stores it beside the request and refuses an answer signed for any other question.
/// A page lead and an audit use a relative window, which cannot be pinned; their bodies are unchanged apart
/// from the `guards` member, which the oracle's body schema does not list and would refuse whole.
contract LastSeenQuestions {
    using Strings for address;
    using Strings for uint256;

    error BadInput();

    /// The one entry point: `kind` 1 = case verdict (a = wallet, b = suspect), 2 = on-chain hop (a = from, b = to),
    /// 3 = page lead (a = wallet, b = suspect, url), 4 = audit (b = target). `questionHash` is zero for kind 4; for
    /// kind 3 the second value is the page's key instead (`pageKey`), since a relative window cannot be pinned.
    function build(
        uint8 kind,
        address a,
        address b,
        uint64 chainId,
        uint64 fromBlock,
        uint64 toBlock,
        uint16 panelSize,
        uint16 quorum,
        string calldata url
    ) external pure returns (bytes memory body, bytes32 questionHash) {
        if (kind == 1) return verdictQuestion(a, b, chainId, fromBlock, toBlock, panelSize, quorum);
        if (kind == 2) return leadQuestion(a, b, chainId, fromBlock, toBlock, panelSize, quorum);
        if (kind == 3) return (linkBody(a, b, chainId, panelSize, quorum, url), pageKey(url));
        return (auditBody(chainId, b, panelSize, quorum), bytes32(0));
    }

    /// Case verdict: did `suspect` take funds out of `wallet` inside the window?
    function verdictQuestion(
        address wallet,
        address suspect,
        uint64 chainId,
        uint64 fromBlock,
        uint64 toBlock,
        uint16 panelSize,
        uint16 quorum
    ) internal pure returns (bytes memory body, bytes32 questionHash) {
        bytes memory w = bytes(wallet.toHexString());
        bytes memory s = bytes(suspect.toHexString());
        bytes memory members = bytes.concat(
            '{"answerType":"bool","chainId":',
            bytes(uint256(chainId).toString()),
            ',"definitions":{"not counted":"Transactions that ',
            w,
            " itself signed and sent, and movements that ",
            w,
            ' authorised with its own signature and another sender only relayed: a user operation (ERC-4337), a permit or Permit2 allowance, a signed order filled by a solver, or a meta-transaction.","take":"A token transfer event or native coin movement from ',
            w
        );
        members = bytes.concat(
            members,
            " to any address, inside a transaction whose sender (tx.from) is ",
            s,
            ", that ",
            w,
            ' did not authorise."}',
            ',"question":"Within the window, did address ',
            s,
            " take tokens or native coin out of wallet ",
            w
        );
        members = bytes.concat(
            members,
            " using transactions that ",
            s,
            " sent itself? Count a transfer out of ",
            w,
            " when the transaction sender is ",
            s
        );
        members = bytes.concat(
            members,
            ", including EIP-7702 transactions that run code as ",
            w,
            '. Answer true if there is at least one."',
            _window(fromBlock, toBlock)
        );
        return _pinned(members, panelSize, quorum);
    }

    /// On-chain hop: did `from` send tokens or native coin to `to` inside the window?
    function leadQuestion(
        address from,
        address to,
        uint64 chainId,
        uint64 fromBlock,
        uint64 toBlock,
        uint16 panelSize,
        uint16 quorum
    ) internal pure returns (bytes memory body, bytes32 questionHash) {
        bytes memory members = bytes.concat(
            '{"answerType":"bool","chainId":',
            bytes(uint256(chainId).toString()),
            ',"definitions":{"send":"A token transfer event or native coin movement whose sender is the first address and whose receiver is the second."}',
            ',"question":"Within the window, did address ',
            bytes(from.toHexString())
        );
        members = bytes.concat(
            members,
            " send tokens or native coin to address ",
            bytes(to.toHexString()),
            '? Answer true if there is at least one such transfer."',
            _window(fromBlock, toBlock)
        );
        return _pinned(members, panelSize, quorum);
    }

    /// Page lead: the panel reads `url`. Reverts BadInput unless the URL is https:// and cannot break the JSON.
    function linkBody(
        address wallet,
        address suspect,
        uint64 chainId,
        uint16 panelSize,
        uint16 quorum,
        string calldata url
    ) internal pure returns (bytes memory) {
        if (!_safeUrl(bytes(url))) revert BadInput();
        bytes memory s = bytes(suspect.toHexString());
        bytes memory head = bytes.concat(
            '{"v":1,"question":"Does the public page at ',
            bytes(url),
            " show evidence that ties address ",
            s,
            " to a specific online account, exchange account, service or person? Address ",
            s,
            " took funds from wallet ",
            bytes(wallet.toHexString())
        );
        return bytes.concat(
            head,
            '. Answer true only if the page itself shows that link.","chainId":',
            bytes(uint256(chainId).toString()),
            ',"window":{"hours":24},"evidence":"panel",',
            _panel(panelSize, quorum),
            // the hunter's page is unknown to the wording screen, so the reading is pinned in definitions and the screen skipped
            ',"definitions":{"ties":"The page shows the address together with an account name, handle, deposit record or other identifier, in a way a reader can check.","missing":"If the page cannot be opened, report inability rather than guessing."},"allowAmbiguous":true}'
        );
    }

    /// Audit: can one privileged account move users' funds out of `target` without their signature?
    function auditBody(uint64 chainId, address target, uint16 panelSize, uint16 quorum)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory t = bytes(target.toHexString());
        bytes memory id = bytes(uint256(chainId).toString());
        bytes memory head = bytes.concat(
            '{"v":1,"question":"Can a single privileged account (an owner, an admin, or a hard-coded address) use the contract at ',
            t,
            " on chain ",
            id,
            ' to move tokens or native coin that users deposited in it or approved to it, to an address of its choosing, without that user signing for the move? Read the contract\'s verified source code. Answer true if yes.","chainId":',
            id,
            ',"window":{"hours":24},"evidence":"panel",',
            _panel(panelSize, quorum)
        );
        return bytes.concat(
            head,
            ',"definitions":{"source":"The verified source on Sourcify: https://sourcify.dev/server/v2/contract/',
            id,
            "/",
            t,
            '?fields=sources . Include code reached through a proxy or delegatecall.","privileged":"Any role or address ordinary users do not hold, including an upgrade admin who can replace the code.","missing":"If no verified source exists, report inability rather than guessing."}}'
        );
    }

    /// The question document's hash (what the oracle signs as `questionHash`) and the full request body.
    function _pinned(bytes memory members, uint16 panelSize, uint16 quorum)
        internal
        pure
        returns (bytes memory body, bytes32 questionHash)
    {
        questionHash = keccak256(bytes.concat(members, "}"));
        body = bytes.concat(members, ",", _panel(panelSize, quorum), "}");
    }

    function _window(uint64 fromBlock, uint64 toBlock) internal pure returns (bytes memory) {
        return bytes.concat(
            ',"v":1,"window":{"fromBlock":',
            bytes(uint256(fromBlock).toString()),
            ',"toBlock":',
            bytes(uint256(toBlock).toString()),
            "}"
        );
    }

    function _panel(uint16 panelSize, uint16 quorum) internal pure returns (bytes memory) {
        return bytes.concat(
            '"panelSize":',
            bytes(uint256(panelSize).toString()),
            ',"quorum":',
            bytes(uint256(quorum).toString()),
            ',"validForSeconds":86400'
        );
    }

    /// The key under which a page counts once per case: the URL without its fragment or query string, without
    /// trailing slashes, with the host lowercased. `https://X.com/p/`, `https://x.com/p#a` and `https://x.com/p?s=1`
    /// all lead the panel to the page `https://x.com/p` and share its key. Paths keep their case.
    function pageKey(string calldata url) public pure returns (bytes32) {
        bytes memory u = bytes(url);
        uint256 n = u.length;
        for (uint256 i = 8; i < n; i++) {
            if (u[i] == "?" || u[i] == "#") {
                n = i;
                break;
            }
        }
        while (n > 8 && u[n - 1] == "/") {
            n--;
        }
        bytes memory k = new bytes(n);
        bool host = true;
        for (uint256 i; i < n; i++) {
            bytes1 ch = u[i];
            if (i >= 8 && ch == "/") host = false;
            if (host && ch >= "A" && ch <= "Z") ch = bytes1(uint8(ch) + 32);
            k[i] = ch;
        }
        return keccak256(k);
    }

    /// https:// followed by 4 to 292 printable characters, none of which could break the JSON the swarm reads.
    function _safeUrl(bytes memory u) internal pure returns (bool) {
        if (u.length < 12 || u.length > 300) return false;
        if (bytes8(u) != bytes8("https://")) return false;
        for (uint256 i = 8; i < u.length; i++) {
            bytes1 ch = u[i];
            if (ch <= 0x20 || ch >= 0x7f || ch == '"' || ch == "\\") return false;
        }
        return true;
    }
}
