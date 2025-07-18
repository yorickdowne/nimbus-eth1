# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sets, algorithm],
  stew/byteutils,
  chronos,
  chronicles,
  stint,
  results,
  eth/common/[base, addresses, accounts, headers, transactions],
  ../../execution_chain/db/[ledger, access_list],
  ../../execution_chain/common/common,
  ../../execution_chain/transaction/call_evm,
  ../../execution_chain/evm/[types, state, evm_errors],
  ./async_evm_backend

from web3/eth_api_types import TransactionArgs, Quantity

export
  async_evm_backend, results, chronos, headers, TransactionArgs, CallResult,
  transactions.AccessList, GasInt

logScope:
  topics = "async_evm"

# The Async EVM uses the Nimbus in-memory EVM to execute transactions using state
# data fetched asyncronously from a supplied state backend.
#
# Rather than wire in the async state lookups into the EVM directly, the approach
# taken here is to optimistically execute the transaction multiple times with the
# goal of building the correct access list so that we can then lookup the accessed
# state from the async state backend, store the state in the in-memory EVM and then
# finally execute the transaction using the correct state. The Async EVM makes
# use of data in memory during the call and therefore each piece of state is never
# fetched more than once. We know we have found the correct access list if it
# doesn't change after another execution of the transaction.
#
# The assumption here is that network lookups for state data are generally much
# slower than the time it takes to execute a transaction in the EVM and therefore
# executing the transaction multiple times should not significally slow down the
# call given that we gain the ability to fetch the state concurrently.
#
# There are multiple reasons for choosing this approach:
# - Firstly updating the existing Nimbus EVM to support using different state
#   backends is difficult and would require making non-trivial changes to the EVM.
# - This new approach allows us to look up the state concurrently in the event that
#   multiple new state keys are discovered after executing the transaction. This
#   should in theory result in improved performance for certain scenarios. The
#   default approach where the state lookups are wired directly into the EVM gives
#   the worst case performance because all state accesses inside the EVM are
#   completely sequential.
#
# Note: The BLOCKHASH opt code is not yet supported by this implementation and so
# transactions which use this opt code will simply get the empty/default hash
# for any requested block. After the Pectra hard fork this opt code will be
# implemented using a system contract with the data stored in the Ethereum state
# trie/s and at that point it should just work without changes to the async evm here.

const
  EVM_CALL_LIMIT = 10_000
  EVM_CALL_GAS_CAP* = 50_000_000.GasInt

type
  AccountQuery = object
    address: Address
    accFut: Future[Opt[Account]]

  StorageQuery = object
    address: Address
    slotKey: UInt256
    storageFut: Future[Opt[UInt256]]

  CodeQuery = object
    address: Address
    codeFut: Future[Opt[seq[byte]]]

  AsyncEvm* = ref object
    com: CommonRef
    backend: AsyncEvmStateBackend

func init(T: type AccountQuery, adr: Address, fut: Future[Opt[Account]]): T =
  T(address: adr, accFut: fut)

func init(
    T: type StorageQuery, adr: Address, slotKey: UInt256, fut: Future[Opt[UInt256]]
): T =
  T(address: adr, slotKey: slotKey, storageFut: fut)

func init(T: type CodeQuery, adr: Address, fut: Future[Opt[seq[byte]]]): T =
  T(address: adr, codeFut: fut)

proc init*(
    T: type AsyncEvm, backend: AsyncEvmStateBackend, networkId: NetworkId = MainNet
): T =
  let com = CommonRef.new(
    DefaultDbMemory.newCoreDbRef(),
    taskpool = nil,
    config = chainConfigForNetwork(networkId),
    initializeDb = false,
    statelessProviderEnabled = true, # Enables collection of witness keys
  )

  AsyncEvm(com: com, backend: backend)

template toCallResult(evmResult: EvmResult[CallResult]): Result[CallResult, string] =
  let callResult =
    ?evmResult.mapErr(
      proc(e: EvmErrorObj): string =
        "EVM execution failed: " & $e.code
    )

  ok(callResult)

proc callFetchingState(
    evm: AsyncEvm,
    vmState: BaseVMState,
    header: Header,
    tx: TransactionArgs,
    optimisticStateFetch: bool,
): Future[Result[CallResult, string]] {.async: (raises: [CancelledError]).} =
  doAssert(tx.to.isSome())
  if tx.gas.isSome():
    doAssert(tx.gas.get().uint64 <= EVM_CALL_GAS_CAP)

  let to = tx.to.get()
  debug "Executing call fetching state", blockNumber = header.number, to

  var
    # Record the keys of fetched accounts, storage and code so that we don't
    # bother to fetch them multiple times
    fetchedAccounts = initHashSet[Address]()
    fetchedStorage = initHashSet[(Address, UInt256)]()
    fetchedCode = initHashSet[Address]()

  # Set code of the 'to' address in the EVM so that we can execute the transaction
  let code = (await evm.backend.getCode(header, to)).valueOr:
    return err("Unable to get code")
  vmState.ledger.setCode(to, code)
  fetchedCode.incl(to)
  debug "Code to be executed", code = code.to0xHex()

  var
    lastWitnessKeys: WitnessTable
    witnessKeys = vmState.ledger.getWitnessKeys()
    evmResult: EvmResult[CallResult]
    evmCallCount = 0

  # Limit the max number of calls to prevent infinite loops and/or DOS in the
  # event of a bug in the implementation.
  while evmCallCount < EVM_CALL_LIMIT:
    debug "Starting AsyncEvm execution", evmCallCount

    vmState.ledger.clearWitnessKeys()
    let sp = vmState.ledger.beginSavepoint()
    evmResult = rpcCallEvm(tx, header, vmState, EVM_CALL_GAS_CAP)
    inc evmCallCount
    vmState.ledger.rollback(sp) # all state changes from the call are reverted

    # Collect the keys after executing the transaction
    lastWitnessKeys = ensureMove(witnessKeys)
    witnessKeys = vmState.ledger.getWitnessKeys()

    try:
      var
        accountQueries = newSeq[AccountQuery]()
        storageQueries = newSeq[StorageQuery]()
        codeQueries = newSeq[CodeQuery]()

      # Loop through the collected keys and fetch the state concurrently.
      # If optimisticStateFetch is enabled then we fetch state for all the witness
      # keys and await all queries before continuing to the next call.
      # If optimisticStateFetch is disabled then we only fetch and then await on
      # one piece of state (the next in the ordered witness keys) while the remaining
      # state queries are still issued in the background just incase the state is
      # needed in the next iteration.
      var stateFetchDone = false
      for k, codeTouched in witnessKeys:
        let (adr, maybeSlot) = k
        if adr == default(Address):
          continue

        if maybeSlot.isSome():
          let slot = maybeSlot.get()
          if (adr, slot) notin fetchedStorage:
            debug "Fetching storage slot", address = adr, slot
            let storageFut = evm.backend.getStorage(header, adr, slot)
            if not stateFetchDone:
              storageQueries.add(StorageQuery.init(adr, slot, storageFut))
              if not optimisticStateFetch:
                stateFetchDone = true
        else:
          if adr notin fetchedAccounts:
            debug "Fetching account", address = adr
            let accFut = evm.backend.getAccount(header, adr)
            if not stateFetchDone:
              accountQueries.add(AccountQuery.init(adr, accFut))
              if not optimisticStateFetch:
                stateFetchDone = true

          if codeTouched and adr notin fetchedCode:
            debug "Fetching code", address = adr
            let codeFut = evm.backend.getCode(header, adr)
            if not stateFetchDone:
              codeQueries.add(CodeQuery.init(adr, codeFut))
              if not optimisticStateFetch:
                stateFetchDone = true

      if optimisticStateFetch:
        # If the witness keys did not change after the last execution then we can
        # stop the execution loop because we have already executed the transaction
        # with the correct state.
        if lastWitnessKeys == witnessKeys:
          break
      else:
        # When optimisticStateFetch is disabled and stateFetchDone is not set then
        # we know that all the state has already been fetched in the last iteration
        # of the loop and therefore we have already executed the transaction with
        # the correct state.
        if not stateFetchDone:
          break

      # Store fetched state in the in-memory EVM
      for q in accountQueries:
        let acc = (await q.accFut).valueOr:
          return err("Unable to get account")
        vmState.ledger.setBalance(q.address, acc.balance)
        vmState.ledger.setNonce(q.address, acc.nonce)
        fetchedAccounts.incl(q.address)

      for q in storageQueries:
        let slotValue = (await q.storageFut).valueOr:
          return err("Unable to get slot")
        vmState.ledger.setStorage(q.address, q.slotKey, slotValue)
        fetchedStorage.incl((q.address, q.slotKey))

      for q in codeQueries:
        let code = (await q.codeFut).valueOr:
          return err("Unable to get code")
        vmState.ledger.setCode(q.address, code)
        fetchedCode.incl(q.address)
    except CancelledError as e:
      raise e
    except CatchableError as e:
      raiseAssert(e.msg) # Shouldn't happen

  evmResult.toCallResult()

proc call(
    evm: AsyncEvm, vmState: BaseVMState, header: Header, tx: TransactionArgs
): Result[CallResult, string] =
  doAssert(tx.to.isSome())
  if tx.gas.isSome():
    doAssert(tx.gas.get().uint64 <= EVM_CALL_GAS_CAP)

  debug "Executing call", blockNumber = header.number, to = tx.to.get()

  vmState.ledger.clearWitnessKeys()
  let
    sp = vmState.ledger.beginSavepoint()
    evmResult = rpcCallEvm(tx, header, vmState, EVM_CALL_GAS_CAP)
  vmState.ledger.rollback(sp) # all state changes from the call are reverted

  evmResult.toCallResult()

proc setupVmState(evm: AsyncEvm, txFrame: CoreDbTxRef, header: Header): BaseVMState =
  let blockContext = BlockContext(
    timestamp: header.timestamp,
    gasLimit: header.gasLimit,
    baseFeePerGas: header.baseFeePerGas,
    prevRandao: header.prevRandao,
    difficulty: header.difficulty,
    coinbase: header.coinbase,
    excessBlobGas: header.excessBlobGas.get(0'u64),
    parentHash: header.computeRlpHash(),
  )
  BaseVMState.new(header, blockContext, evm.com, txFrame)

func validateSetDefaults(tx: TransactionArgs): Result[TransactionArgs, string] =
  if tx.to.isNone():
    return err("to address is required")
  if tx.gas.isSome() and tx.gas.get().uint64 > EVM_CALL_GAS_CAP:
    return err("gas larger than max allowed")

  var tx = tx
  if tx.`from`.isNone():
    tx.`from` = Opt.some(default(Address))
  if tx.gas.isNone():
    tx.gas = Opt.some(EVM_CALL_GAS_CAP.Quantity)

  ok(ensureMove(tx))

proc call*(
    evm: AsyncEvm, header: Header, tx: TransactionArgs, optimisticStateFetch = true
): Future[Result[CallResult, string]] {.async: (raises: [CancelledError]).} =
  let
    tx = ?validateSetDefaults(tx)
    txFrame = evm.com.db.baseTxFrame().txFrameBegin()
  defer:
    txFrame.dispose() # always dispose state changes

  let
    vmState = evm.setupVmState(txFrame, header)
    callResult =
      ?(await evm.callFetchingState(vmState, header, tx, optimisticStateFetch))

  ok(callResult)

proc createAccessList*(
    evm: AsyncEvm, header: Header, tx: TransactionArgs, optimisticStateFetch = true
): Future[Result[(transactions.AccessList, Opt[string], GasInt), string]] {.
    async: (raises: [CancelledError])
.} =
  let
    tx = ?validateSetDefaults(tx)
    txFrame = evm.com.db.baseTxFrame().txFrameBegin()
  defer:
    txFrame.dispose() # always dispose state changes

  let
    vmState = evm.setupVmState(txFrame, header)
    callResult =
      ?(await evm.callFetchingState(vmState, header, tx, optimisticStateFetch))
    witnessKeys = vmState.ledger.getWitnessKeys()
    fromAdr = tx.`from`.get(default(Address))

  # Build the access list from the witness keys and then execute the transaction
  # one more time using the final access list which will impact the gas used value
  # returned in the callResult.

  var al = access_list.AccessList.init()
  for k, codeTouched in witnessKeys:
    let (adr, maybeSlot) = k
    if adr == fromAdr:
      continue

    if maybeSlot.isSome():
      al.add(adr, maybeSlot.get())
    else:
      al.add(adr)

  var txWithAl = ensureMove(tx)
  txWithAl.accessList = Opt.some(al.getAccessList())
    # converts to transactions.AccessList

  let
    finalCallResult = ?evm.call(vmState, header, txWithAl)
    error =
      if finalCallResult.error.len() > 0:
        Opt.some(finalCallResult.error)
      else:
        Opt.none(string)

  # Sort the access list
  var accessList = txWithAl.accessList.get(@[])
  for a in accessList.mitems():
    a.storageKeys.sort(
      proc(x, y: Bytes32): int =
        cmp(x.data, y.data)
    )
  accessList.sort(
    proc(x, y: AccessPair): int =
      cmp(x.address.data, y.address.data)
  )

  ok((accessList, error, finalCallResult.gasUsed))

proc estimateGas*(
    evm: AsyncEvm, header: Header, tx: TransactionArgs, optimisticStateFetch = true
): Future[Result[GasInt, string]] {.async: (raises: [CancelledError]).} =
  let
    tx = ?validateSetDefaults(tx)
    txFrame = evm.com.db.baseTxFrame().txFrameBegin()
  defer:
    txFrame.dispose() # always dispose state changes

  let
    vmState = evm.setupVmState(txFrame, header)
    callResult =
      ?(await evm.callFetchingState(vmState, header, tx, optimisticStateFetch))
  # we only invoke callFetchingState in order to collect the state in the BaseVMState
  discard callResult

  let
    evmResult = rpcEstimateGas(tx, header, vmState, EVM_CALL_GAS_CAP)
    gasEstimate =
      ?evmResult.mapErr(
        proc(e: EvmErrorObj): string =
          "EVM execution failed: " & $e.code
      )
  ok(gasEstimate)
