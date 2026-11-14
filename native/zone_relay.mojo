# The zone relay state machine: a line-for-line port of src/zone_relay.c.
# No I/O, no clock, and no read of a frame byte. The caller owns the Zone.
# A Zone is a handful of raw pointers so it can live inside a BEAM resource.
from std.ffi import external_call, c_size_t

comptime ZR_SLOTS = 4
comptime ZR_FRAME_BYTES = 1200
comptime ZR_FRAME_MAX = 1472
comptime ZR_SILENT_TICKS = 192
comptime ZR_SEND_TICKS = 6
comptime ZR_OPEN_TICKS = 5
comptime HALVES = ZR_SLOTS * 2

comptime Bytes = Pointer[UInt8, MutUntrackedOrigin]


def zr_calloc(n: Int) -> Bytes:
    var mem = external_call["calloc", Optional[Bytes]](c_size_t(1), c_size_t(n))
    if not mem:
        external_call["abort", NoneType]()
    return mem.value()


@fieldwise_init
struct Zone(RegisterPassable):
    var people: Pointer[Int32, MutUntrackedOrigin]
    var heard: Pointer[UInt64, MutUntrackedOrigin]
    var due: Pointer[UInt64, MutUntrackedOrigin]
    var lens: Pointer[Int32, MutUntrackedOrigin]
    var store: Bytes
    var now: UInt64
    var unread_count: UInt64

    @staticmethod
    def create() -> Zone:
        var z = Zone(
            zr_calloc(ZR_SLOTS * 4).unsafe_bitcast[Int32](),
            zr_calloc(ZR_SLOTS * 8).unsafe_bitcast[UInt64](),
            zr_calloc(HALVES * 8).unsafe_bitcast[UInt64](),
            zr_calloc(HALVES * 4).unsafe_bitcast[Int32](),
            zr_calloc(HALVES * ZR_FRAME_MAX),
            UInt64(0),
            UInt64(0),
        )
        z.reset()
        return z^

    def destroy(self):
        external_call["free", NoneType](self.people.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](self.heard.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](self.due.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](self.lens.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](self.store.unsafe_bitcast[NoneType]())

    def _blank(mut self, s: Int):
        for h in range(2):
            var at = s * 2 + h
            for i in range(ZR_FRAME_MAX):
                self.store[unsafe_offset = at * ZR_FRAME_MAX + i] = 0
            self.lens[unsafe_offset=at] = Int32(ZR_FRAME_BYTES)

    def reset(mut self):
        for s in range(ZR_SLOTS):
            self.people[unsafe_offset=s] = -1
            self.heard[unsafe_offset=s] = 0
            self.due[unsafe_offset = s * 2] = 0
            self.due[unsafe_offset = s * 2 + 1] = 0
            self._blank(s)
        self.now = 0
        self.unread_count = 0

    def join(mut self, person: Int32) -> Int:
        for s in range(ZR_SLOTS):
            if self.people[unsafe_offset=s] == person:
                return s
        for s in range(ZR_SLOTS):
            if self.people[unsafe_offset=s] == -1:
                self.people[unsafe_offset=s] = person
                self.heard[unsafe_offset=s] = self.now
                return s
        return -1

    def leave(mut self, person: Int32) -> Int:
        for s in range(ZR_SLOTS):
            if self.people[unsafe_offset=s] == person:
                self.people[unsafe_offset=s] = -1
                self._blank(s)
                return 1
        return 0

    def person_at(self, slot: Int) -> Int32:
        if slot < 0 or slot >= ZR_SLOTS:
            return -1
        return self.people[unsafe_offset=slot]

    # `src` holds `n` bytes. They are copied, never read.
    def put(mut self, slot: Int, half: Int, src: Bytes, n: Int) -> Int:
        if slot < 0 or slot >= ZR_SLOTS or half < 0 or half > 1:
            return 0
        if self.people[unsafe_offset=slot] == -1:
            return 0
        var at = slot * 2 + half
        if self.now + UInt64(ZR_OPEN_TICKS) < self.due[unsafe_offset=at]:
            self.unread_count += 1
            return 0
        if n > ZR_FRAME_MAX:
            return 0
        var d = self.due[unsafe_offset=at]
        var base = d if d > self.now else self.now
        self.due[unsafe_offset=at] = base + UInt64(ZR_OPEN_TICKS)
        for i in range(n):
            self.store[unsafe_offset = at * ZR_FRAME_MAX + i] = src[unsafe_offset=i]
        self.lens[unsafe_offset=at] = Int32(n)
        self.heard[unsafe_offset=slot] = self.now
        return 1

    # Index (0..7) of frame k (0..5) for a viewer, or -1 when k is out of range.
    # A viewer outside 0..3 is not checked, as in the C and the model.
    def _half_index(self, viewer: Int, k: Int) -> Int:
        if k < 0 or k >= (ZR_SLOTS - 1) * 2:
            return -1
        var other = k // 2
        var slot = other + 1 if other >= viewer else other
        return slot * 2 + k % 2

    def frame_len(self, viewer: Int, k: Int) -> Int:
        var at = self._half_index(viewer, k)
        if at < 0:
            return 0
        return Int(self.lens[unsafe_offset=at])

    # Offset into `store` of frame k for a viewer; 0 when k is out of range.
    def frame_at(self, viewer: Int, k: Int) -> Int:
        var at = self._half_index(viewer, k)
        if at < 0:
            return 0
        return at * ZR_FRAME_MAX

    def tick(mut self) -> UInt64:
        self.now += 1
        for s in range(ZR_SLOTS):
            if self.people[unsafe_offset=s] != -1 and self.now - self.heard[unsafe_offset=s] > UInt64(ZR_SILENT_TICKS):
                self.people[unsafe_offset=s] = -1
                self._blank(s)
        return self.now

    def unread(self) -> UInt64:
        return self.unread_count
