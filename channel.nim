## Based on https://github.com/mratsim/weave/blob/5696d94e6358711e840f8c0b7c684fcc5cbd4472/unused/channels/channels_legacy.nim
## Primary author: Mratsim

import
  # Standard library
  std/[locks, atomics, isolation]
import system/ansi_c

# Channel (Shared memory channels)
# ----------------------------------------------------------------------------------

const
  CacheLineSize {.intdefine.} = 64 # TODO: some Samsung phone have 128 cache-line
  ChannelCacheSize* {.intdefine.} = 100

type
  ChannelBufKind = enum
    Unbuffered # Unbuffered (blocking) channel
    Buffered   # Buffered (non-blocking channel)

  ChannelKind* = enum
    Mpmc # Multiple producer, multiple consumer
    Mpsc # Multiple producer, single consumer
    Spsc # Single producer, single consumer

  ChannelRaw* = ptr ChannelObj
  ChannelObj = object
    headLock, tailLock: Lock
    notFullCond: Cond
    notEmptyCond: Cond
    owner: int32
    impl: ChannelKind
    closed: Atomic[bool]
    size: int32
    itemsize: int32 # up to itemsize bytes can be exchanged over this channel
    head: int32     # Items are taken from head and new items are inserted at tail
    pad: array[CacheLineSize-sizeof(int32), byte] # Separate by at-least a cache line
    tail: int32
    buffer: ptr UncheckedArray[byte]

  # TODO: Replace this cache by generic ObjectPools
  #       We can use HList or a Table or thread-local globals
  #       to keep the list of object pools
  ChannelCache = ptr ChannelCacheObj
  ChannelCacheObj = object
    next: ChannelCache
    chanSize: int32
    chanN: int32
    chanKind: ChannelKind
    numCached: int32
    cache: array[ChannelCacheSize, ChannelRaw]

# ----------------------------------------------------------------------------------

template incmod(idx, size: int32): int32 =
  (idx + 1) mod size

# template decmod(idx, size: int32): int32 =
#   (idx - 1) mod size

template numItems(chan: ChannelRaw): int32 =
  (chan.size + chan.tail - chan.head) mod chan.size

template isFull(chan: ChannelRaw): bool =
  chan.numItems() == chan.size - 1

template isEmpty(chan: ChannelRaw): bool =
  chan.head == chan.tail

# Unbuffered / synchronous channels
# ----------------------------------------------------------------------------------

template numItemsUnbuf(chan: ChannelRaw): int32 =
  chan.head

template isFullUnbuf(chan: ChannelRaw): bool =
  chan.head == 1

template isEmptyUnbuf(chan: ChannelRaw): bool =
  chan.head == 0

# ChannelRaw kinds
# ----------------------------------------------------------------------------------

func isBuffered(chan: ChannelRaw): bool =
  chan.size - 1 > 0

func isUnbuffered(chan: ChannelRaw): bool =
  assert chan.size >= 0
  chan.size - 1 == 0

# ChannelRaw status and properties
# ----------------------------------------------------------------------------------

proc isClosed(chan: ChannelRaw): bool {.inline.} = load(chan.closed, moRelaxed)
proc capacity(chan: ChannelRaw): int32 {.inline.} = chan.size - 1

proc peek*(chan: ChannelRaw): int32 =
  (if chan.isUnbuffered(): numItemsUnbuf(chan) else: numItems(chan))

# Per-thread channel cache
# ----------------------------------------------------------------------------------

var channelCache {.threadvar.}: ChannelCache
var channelCacheLen {.threadvar.}: int32

proc allocChannelCache(size, n: int32, impl: ChannelKind): bool =
  ## Allocate a free list for storing channels of a given type
  var p = channelCache

  # Avoid multiple free lists for the exact same type of channel
  while not p.isNil:
    if size == p.chanSize and n == p.chanN and impl == p.chanKind:
      return false
    p = p.next

  p = cast[ptr ChannelCacheObj](c_malloc(csize_t sizeof(ChannelCacheObj)))
  if p.isNil:
    raise newException(OutOfMemDefect, "Could not allocate memory")

  p.chanSize = size
  p.chanN = n
  p.chanKind = impl
  p.numCached = 0

  p.next = channelCache
  channelCache = p
  inc channelCacheLen
  return true

proc freeChannelCache*() =
  ## Frees the entire channel cache, including all channels
  var p = channelCache
  var q: ChannelCache

  while not p.isNil:
    q = p.next
    for i in 0 ..< p.numCached:
      let chan = p.cache[i]
      if not chan.buffer.isNil:
        c_free(chan.buffer)
      deinitLock(chan.headLock)
      deinitLock(chan.tailLock)
      deinitCond(chan.notFullCond)
      deinitCond(chan.notEmptyCond)
      c_free(chan)
    c_free(p)
    dec channelCacheLen
    p = q

  assert(channelCacheLen == 0)
  channelCache = nil

# Channels memory ops
# ----------------------------------------------------------------------------------

proc allocChannel*(size, n: int32, impl: ChannelKind): ChannelRaw =
  when ChannelCacheSize > 0:
    var p = channelCache

    while not p.isNil:
      if size == p.chanSize and n == p.chanN and impl == p.chanKind:
        # Check if free list contains channel
        if p.numCached > 0:
          dec p.numCached
          result = p.cache[p.numCached]
          assert(result.isEmpty())
          return
        else:
          # All the other lists in cache won't match
          break
      p = p.next

  result = cast[ChannelRaw](c_malloc(csize_t sizeof(ChannelObj)))
  if result.isNil:
    raise newException(OutOfMemDefect, "Could not allocate memory")

  # To buffer n items, we allocate for n+1
  result.buffer = cast[ptr UncheckedArray[byte]](c_malloc(csize_t (n+1)*size))
  if result.buffer.isNil:
    raise newException(OutOfMemDefect, "Could not allocate memory")

  initLock(result.headLock)
  initLock(result.tailLock)
  initCond(result.notFullCond)
  initCond(result.notEmptyCond)

  result.owner = -1 # TODO
  result.impl = impl
  result.closed.store(false, moRelaxed) # We don't need atomic here, how to?
  result.size = n+1
  result.itemsize = size
  result.head = 0
  result.tail = 0

  when ChannelCacheSize > 0:
    # Allocate a cache as well if one of the proper size doesn't exist
    discard allocChannelCache(size, n, impl)

proc freeChannel*(chan: ChannelRaw) =
  if chan.isNil:
    return

  when ChannelCacheSize > 0:
    var p = channelCache
    while not p.isNil:
      if chan.itemsize == p.chanSize and
         chan.size-1 == p.chanN and
         chan.impl == p.chanKind:
        if p.numCached < ChannelCacheSize:
          # If space left in cache, cache it
          p.cache[p.numCached] = chan
          inc p.numCached
          return
        else:
          # All the other lists in cache won't match
          break
      p = p.next

  if not chan.buffer.isNil:
    c_free(chan.buffer)

  deinitLock(chan.headLock)
  deinitLock(chan.tailLock)
  deinitCond(chan.notFullCond)
  deinitCond(chan.notEmptyCond)

  c_free(chan)

# MPMC Channels (Multi-Producer Multi-Consumer)
# ----------------------------------------------------------------------------------

proc sendUnbufferedMpmc(chan: ChannelRaw, data: sink pointer, size: int32, nonBlocking: bool): bool =
  if nonBlocking and chan.isFullUnbuf():
    return false

  acquire(chan.headLock)

  if nonBlocking and chan.isFullUnbuf():
    # Another thread was faster
    release(chan.headLock)
    return false

  while chan.isFullUnbuf():
    wait(chan.notFullcond, chan.headLock)

  assert chan.isEmptyUnbuf()
  assert size <= chan.itemsize
  copyMem(chan.buffer, data, size)

  chan.head = 1

  release(chan.headLock)
  signal(chan.notEmptyCond)
  return true

proc sendMpmc(chan: ChannelRaw, data: sink pointer, size: int32, nonBlocking: bool): bool =
  assert not chan.isNil # TODO not nil compiler constraint
  assert not data.isNil

  if isUnbuffered(chan):
    return sendUnbufferedMpmc(chan, data, size, nonBlocking)

  if nonBlocking and chan.isFull():
    return false

  acquire(chan.tailLock)


  if nonBlocking and chan.isFull():
    # Another thread was faster
    release(chan.tailLock)
    return false

  while chan.isFull():
    wait(chan.notFullcond, chan.tailLock)

  assert not chan.isFull
  assert size <= chan.itemsize

  copyMem(chan.buffer[chan.tail * chan.itemsize].addr, data, size)

  chan.tail = chan.tail.incmod(chan.size)

  release(chan.tailLock)
  signal(chan.notEmptyCond)
  return true

proc recvUnbufferedMpmc(chan: ChannelRaw, data: pointer, size: int32, nonBlocking: bool): bool =
  if nonBlocking and chan.isEmptyUnbuf():
    return false

  acquire(chan.headLock)

  if nonBlocking and chan.isEmptyUnbuf():
    # Another thread was faster
    release(chan.headLock)
    return false

  while chan.isEmptyUnbuf:
    wait(chan.notEmptyCond, chan.headLock)

  assert chan.isFullUnbuf()
  assert size <= chan.itemsize
  copyMem(data, chan.buffer, size)

  chan.head = 0
  assert chan.isEmptyUnbuf

  release(chan.headLock)
  signal(chan.notFullCond)
  return true

proc recvMpmc(chan: ChannelRaw, data: pointer, size: int32, nonBlocking: bool): bool =
  assert not chan.isNil # TODO not nil compiler constraint
  assert not data.isNil

  if isUnbuffered(chan):
    return recvUnbufferedMpmc(chan, data, size, nonBlocking)

  if nonBlocking and chan.isEmpty():
    return false

  acquire(chan.headLock)

  if nonBlocking and chan.isEmpty():
    # Another thread took the last data
    release(chan.headLock)
    return false

  while chan.isEmpty():
    wait(chan.notEmptyCond, chan.headLock)

  assert not chan.isEmpty()
  assert size <= chan.itemsize
  copyMem(data, chan.buffer[chan.head * chan.itemsize].addr, size)

  chan.head = chan.head.incmod(chan.size)
  release(chan.headLock)
  signal(chan.notFullCond)
  return true

proc channel_close_mpmc(chan: ChannelRaw): bool =
  # Unsynchronized

  if chan.isClosed():
    # ChannelRaw already closed
    return false

  store(chan.closed, true, moRelaxed)
  return true

proc channel_open_mpmc(chan: ChannelRaw): bool =
  # Unsynchronized

  if not chan.isClosed:
    # ChannelRaw already open
    return false

  store(chan.closed, false, moRelaxed)
  return true

# MPSC Channels (Multi-Producer Single-Consumer)
# ----------------------------------------------------------------------------------

proc channel_send_mpsc(chan: ChannelRaw, data: sink pointer, size: int32, nonBlocking: bool): bool =
  # Cannot be inline due to function table
  sendMpmc(chan, data, size, nonBlocking)

proc channel_recv_unbuffered_mpsc(chan: ChannelRaw, data: pointer, size: int32, nonBlocking: bool): bool =
  # Single consumer, no lock needed on reception
  if nonBlocking and chan.isEmptyUnbuf():
    return false

  while chan.isEmptyUnbuf():
    cpuRelax()

  assert chan.isFullUnbuf
  assert size <= chan.itemsize

  copyMem(data, chan.buffer, size)
  fence(moSequentiallyConsistent)

  chan.head = 0
  signal(chan.notFullCond)
  return true

proc channel_recv_mpsc(chan: ChannelRaw, data: pointer, size: int32, nonBlocking: bool): bool =
  # Single consumer, no lock needed on reception
  assert not chan.isNil # TODO not nil compiler constraint
  assert not data.isNil

  if isUnbuffered(chan):
    return channel_recv_unbuffered_mpsc(chan, data, size, nonBlocking)

  if nonBlocking and chan.isEmpty():
    return false

  while chan.isEmpty():
    cpuRelax()

  assert not chan.isEmpty()
  assert size <= chan.itemsize

  copyMem(data, chan.buffer[chan.head * chan.itemsize].addr, size)

  let newHead = chan.head.incmod(chan.size)
  fence(moSequentiallyConsistent)

  chan.head = newHead
  signal(chan.notFullCond)
  return true

proc channel_close_mpsc(chan: ChannelRaw): bool =
  # Unsynchronized
  assert not chan.isNil

  if chan.isClosed():
    # Already closed
    result = false
  else:
    chan.closed.store(true, moRelaxed)
    result = true

proc channel_open_mpsc(chan: ChannelRaw): bool =
  # Unsynchronized
  assert not chan.isNil

  if not chan.isClosed():
    # Already open
    result = false
  else:
    chan.closed.store(false, moRelaxed)
    result = true

# SPSC Channels (Single-Producer Single-Consumer)
# ----------------------------------------------------------------------------------

proc channel_send_unbuffered_spsc(chan: ChannelRaw, data: sink pointer, size: int32, nonBlocking: bool): bool =
  if nonBlocking and chan.isFullUnbuf:
    return false

  while chan.isFullUnbuf:
    cpuRelax()

  assert chan.isEmptyUnbuf
  assert size <= chan.itemsize
  copyMem(chan.buffer, data, size)

  fence(moSequentiallyConsistent)

  chan.head = 1
  signal(chan.notEmptyCond)
  return true

proc channel_send_spsc(chan: ChannelRaw, data: sink pointer, size: int32, nonBlocking: bool): bool =
  assert not chan.isNil
  assert not data.isNil

  if chan.isUnbuffered():
    return channel_send_unbuffered_spsc(chan, data, size, nonBlocking)

  if nonBlocking and chan.isFull():
    return false

  while chan.isFull():
    cpuRelax()

  assert not chan.isFull()
  assert size <= chan.itemsize
  copyMem(chan.buffer[chan.tail * chan.itemsize].addr, data, size)

  let newTail = chan.tail.incmod(chan.size)

  fence(moSequentiallyConsistent)

  chan.tail = newTail
  signal(chan.notEmptyCond)
  return true

proc channel_recv_spsc(chan: ChannelRaw, data: pointer, size: int32, nonBlocking: bool): bool =
  # Cannot be inline due to function table
  channel_recv_mpsc(chan, data, size, nonBlocking)

proc channel_close_spsc(chan: ChannelRaw): bool =
  # Unsynchronized
  assert not chan.isNil

  if chan.isClosed():
    # Already closed
    result = false
  else:
    chan.closed.store(true, moRelaxed)
    result = true

proc channel_open_spsc(chan: ChannelRaw): bool =
  # Unsynchronized
  assert not chan.isNil

  if not chan.isClosed():
    # Already open
    result = false
  else:
    chan.closed.store(false, moRelaxed)
    result = true

# "Generic" dispatch
# ----------------------------------------------------------------------------------

const
  send_fn = [
    Mpmc: sendMpmc,
    Mpsc: channel_send_mpsc,
    Spsc: channel_send_spsc
  ]

  recv_fn = [
    Mpmc: recvMpmc,
    Mpsc: channel_recv_mpsc,
    Spsc: channel_recv_spsc
  ]

  close_fn = [
    Mpmc: channel_close_mpmc,
    Mpsc: channel_close_mpsc,
    Spsc: channel_close_spsc
  ]

  open_fn = [
    Mpmc: channel_open_mpmc,
    Mpsc: channel_open_mpsc,
    Spsc: channel_open_spsc
  ]

proc channel_send(chan: ChannelRaw, data: sink pointer, size: int32, nonBlocking: bool): bool {.inline.} =
  ## Send item to the channel (FIFO queue)
  ## (Insert at last)
  send_fn[chan.impl](chan, data, size, nonBlocking)

proc channel_receive(chan: ChannelRaw, data: pointer, size: int32, nonBlocking: bool): bool {.inline.} =
  ## Receive an item from the channel
  ## (Remove the first item)
  recv_fn[chan.impl](chan, data, size, nonBlocking)

proc channel_close(chan: ChannelRaw): bool {.inline.} =
  ## Close a channel
  close_fn[chan.impl](chan)

proc channel_open(chan: ChannelRaw): bool {.inline.} =
  ## (Re)open a channel
  open_fn[chan.impl](chan)

# Weave API
# ----------------------------------------------------------------------------------

type
  Chan*[T] = object ## Typed channels
    d: ChannelRaw

proc `=`[T](dest: var Chan[T]; src: Chan[T]) {.error.}

proc `=destroy`[T](c: var Chan[T]) =
  if c.d.buffer != nil: freeChannel(c.d)

proc channel_send[T](chan: Chan[T], data: T, size: int32, nonBlocking: bool): bool {.inline.} =
  ## Send item to the channel (FIFO queue)
  ## (Insert at last)
  send_fn[chan.d.impl](chan.d, data.unsafeAddr, size, nonBlocking)

proc channel_receive[T](chan: Chan[T], data: ptr T, size: int32, nonBlocking: bool): bool {.inline.} =
  ## Receive an item from the channel
  ## (Remove the first item)
  recv_fn[chan.d.impl](chan.d, data, size, nonBlocking)

func trySend*[T](c: Chan[T], src: sink Isolated[T]): bool {.inline.} =
  var data = src.extract
  channel_send(c, data, int32 sizeof(data), true)
  when defined(gcDestructors):
    wasMoved(data)

func tryRecv*[T](c: Chan[T], dst: var T): bool {.inline.} =
  channel_receive(c, dst.addr, int32 sizeof(dst), true)

func send*[T](c: Chan[T], src: sink Isolated[T]) {.inline.} =
  var data = src.extract
  discard channel_send(c, data, int32 sizeof(data), false)
  when defined(gcDestructors):
    wasMoved(data)

proc send*[T](c: var Chan[T]; src: sink T) =
  discard channel_send(c, src, int32 sizeof(src), false)
  when defined(gcDestructors):
    wasMoved(src)

func recv*[T](c: Chan[T], dst: var T) {.inline.} =
  discard channel_receive(c, dst.addr, int32 sizeof(dst), false)

func recvIso*[T](c: Chan[T]): Isolated[T] {.inline.} =
  var dst: T
  discard channel_receive(c, dst.addr, int32 sizeof(dst), false)
  result = isolate(dst)

func open*[T](c: Chan[T]): bool {.inline.} =
  result = c.d.channel_open()

func close*[T](c: Chan[T]): bool {.inline.} =
  result = c.d.channel_close()

func peek*[T](c: Chan[T]): int32 {.inline.} = peek(c.d)

proc initChan*[T](elements = 30, kind = Mpmc): Chan[T] =
  result = Chan[T](d: allocChannel(int32 sizeof(T), elements.int32, kind))

proc delete*[T](c: var Chan[T]) {.inline.} =
  freeChannel(c.d)
