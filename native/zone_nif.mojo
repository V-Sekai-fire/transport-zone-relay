# Elixir.ZoneRelay.Nif: one zone as a BEAM resource. The Elixir side owns the
# sockets and the 64 Hz tick; every rule of the relay runs here, in Mojo.
# A zone is touched by one Elixir process at a time (its owner), so no lock.
from std.ffi import c_char, c_int, c_size_t, c_uint, c_ulong, external_call
from std.sys import size_of
from mojoler.abi.otp_nif import (
    ErlNifBinary,
    ErlNifEntry,
    ErlNifFunc,
    enif_alloc_resource,
    enif_get_int,
    enif_get_resource,
    enif_inspect_binary,
    enif_make_atom,
    enif_make_badarg,
    enif_make_int,
    enif_make_new_binary,
    enif_make_resource,
    enif_make_ulong,
    enif_priv_data,
    enif_release_resource,
)
from mojoler.abi.prim import alloc_funcs, callback_opt, make_entry, must_alloc, must_free
from zone_relay import Zone, Bytes, ZR_FRAME_MAX

comptime Env = Pointer[NoneType, MutUntrackedOrigin]
comptime Argv = Pointer[c_ulong, MutUntrackedOrigin]


@fieldwise_init
struct Types(RegisterPassable):
    var zone: Pointer[NoneType, MutUntrackedOrigin]


def lit(text: StaticString) -> Pointer[c_char, ImmStaticOrigin]:
    return text.as_c_string_span().ptr()


def types(env: Env) -> Pointer[Types, MutUntrackedOrigin]:
    return enif_priv_data(env).unsafe_bitcast[Types]()


def zone_dtor(
    env: Env, obj: Pointer[NoneType, MutUntrackedOrigin]
) abi("C"):
    _ = env
    obj.unsafe_bitcast[Zone]()[].destroy()


def open_type(env: Env) -> Pointer[NoneType, MutUntrackedOrigin]:
    var tried = c_int(0)
    return external_call["enif_open_resource_type", Pointer[NoneType, MutUntrackedOrigin]](
        env, lit("Elixir.ZoneRelay.Nif"), lit("zone"), zone_dtor, c_int(1), Pointer(to=tried)
    )


def load(
    env: Env,
    priv: Pointer[Pointer[NoneType, MutUntrackedOrigin], MutUntrackedOrigin],
    _info: c_ulong,
) abi("C") -> c_int:
    var box = must_alloc(c_size_t(size_of[Types]())).unsafe_bitcast[Types]()
    box[] = Types(open_type(env))
    priv[] = box.unsafe_bitcast[NoneType]()
    return c_int(0)


def unload(env: Env, priv: Pointer[NoneType, MutUntrackedOrigin]) abi("C"):
    _ = env
    must_free(priv)


def upgrade(
    env: Env,
    priv: Pointer[Pointer[NoneType, MutUntrackedOrigin], MutUntrackedOrigin],
    old: Pointer[Pointer[NoneType, MutUntrackedOrigin], MutUntrackedOrigin],
    info: c_ulong,
) abi("C") -> c_int:
    _ = env
    _ = priv
    _ = old
    _ = info
    return c_int(1)


def bad(env: Env) -> c_ulong:
    return enif_make_badarg(env)


def get_zone(env: Env, term: c_ulong) -> Optional[Pointer[Zone, MutUntrackedOrigin]]:
    var slot = must_alloc(c_size_t(8))
    var box = slot.unsafe_bitcast[Pointer[NoneType, MutUntrackedOrigin]]()
    var rc = enif_get_resource(env, term, types(env)[].zone, box)
    var obj = box[]
    must_free(slot)
    if rc == 0:
        return None
    return obj.unsafe_bitcast[Zone]()


def get_i(env: Env, term: c_ulong) -> Optional[Int]:
    var n = c_int(0)
    if enif_get_int(env, term, Pointer(to=n)) == 0:
        return None
    return Int(n)


def new(env: Env, argc: c_int, argv: Argv) abi("C") -> c_ulong:
    _ = argv
    if argc != 0:
        return bad(env)
    var obj = enif_alloc_resource(types(env)[].zone, c_size_t(size_of[Zone]()))
    obj.unsafe_bitcast[Zone]()[] = Zone.create()
    var term = enif_make_resource(env, obj)
    enif_release_resource(obj)
    return term


def reset(env: Env, argc: c_int, argv: Argv) abi("C") -> c_ulong:
    if argc != 1:
        return bad(env)
    var z = get_zone(env, argv[unsafe_offset=0])
    if not z:
        return bad(env)
    z.value()[].reset()
    return enif_make_atom(env, lit("ok"))


def join(env: Env, argc: c_int, argv: Argv) abi("C") -> c_ulong:
    if argc != 2:
        return bad(env)
    var z = get_zone(env, argv[unsafe_offset=0])
    var p = get_i(env, argv[unsafe_offset=1])
    if not z or not p:
        return bad(env)
    return enif_make_int(env, c_int(z.value()[].join(Int32(p.value()))))


def leave(env: Env, argc: c_int, argv: Argv) abi("C") -> c_ulong:
    if argc != 2:
        return bad(env)
    var z = get_zone(env, argv[unsafe_offset=0])
    var p = get_i(env, argv[unsafe_offset=1])
    if not z or not p:
        return bad(env)
    return enif_make_int(env, c_int(z.value()[].leave(Int32(p.value()))))


def person_at(env: Env, argc: c_int, argv: Argv) abi("C") -> c_ulong:
    if argc != 2:
        return bad(env)
    var z = get_zone(env, argv[unsafe_offset=0])
    var s = get_i(env, argv[unsafe_offset=1])
    if not z or not s:
        return bad(env)
    return enif_make_int(env, c_int(z.value()[].person_at(s.value())))


def put(env: Env, argc: c_int, argv: Argv) abi("C") -> c_ulong:
    if argc != 4:
        return bad(env)
    var z = get_zone(env, argv[unsafe_offset=0])
    var slot = get_i(env, argv[unsafe_offset=1])
    var half = get_i(env, argv[unsafe_offset=2])
    if not z or not slot or not half:
        return bad(env)
    var bin = must_alloc(c_size_t(size_of[ErlNifBinary]())).unsafe_bitcast[ErlNifBinary]()
    if enif_inspect_binary(env, argv[unsafe_offset=3], bin) == 0:
        must_free(bin)
        return bad(env)
    var taken = z.value()[].put(slot.value(), half.value(), bin[].data, Int(bin[].size))
    must_free(bin)
    return enif_make_int(env, c_int(taken))


def frame(env: Env, argc: c_int, argv: Argv) abi("C") -> c_ulong:
    if argc != 3:
        return bad(env)
    var z = get_zone(env, argv[unsafe_offset=0])
    var viewer = get_i(env, argv[unsafe_offset=1])
    var k = get_i(env, argv[unsafe_offset=2])
    if not z or not viewer or not k:
        return bad(env)
    var n = z.value()[].frame_len(viewer.value(), k.value())
    var at = z.value()[].frame_at(viewer.value(), k.value())
    var term = c_ulong(0)
    var out = enif_make_new_binary(env, c_size_t(n), Pointer(to=term))
    for i in range(n):
        out[unsafe_offset=i] = z.value()[].store[unsafe_offset = at + i]
    return term


def tick(env: Env, argc: c_int, argv: Argv) abi("C") -> c_ulong:
    if argc != 1:
        return bad(env)
    var z = get_zone(env, argv[unsafe_offset=0])
    if not z:
        return bad(env)
    return enif_make_ulong(env, c_ulong(z.value()[].tick()))


def unread(env: Env, argc: c_int, argv: Argv) abi("C") -> c_ulong:
    if argc != 1:
        return bad(env)
    var z = get_zone(env, argv[unsafe_offset=0])
    if not z:
        return bad(env)
    return enif_make_ulong(env, c_ulong(z.value()[].unread()))


def put_fn(
    funcs: Pointer[ErlNifFunc, MutUntrackedOrigin],
    i: Int,
    name: StaticString,
    arity: Int,
    f: def(env: Env, argc: c_int, argv: Argv) abi("C") thin -> c_ulong,
):
    funcs[unsafe_offset=i] = ErlNifFunc(lit(name), c_uint(arity), f, c_uint(0))


@export("nif_init")
def nif_init() abi("C") -> Pointer[ErlNifEntry, MutUntrackedOrigin]:
    var funcs = alloc_funcs(9)
    put_fn(funcs, 0, "new", 0, new)
    put_fn(funcs, 1, "reset", 1, reset)
    put_fn(funcs, 2, "join", 2, join)
    put_fn(funcs, 3, "leave", 2, leave)
    put_fn(funcs, 4, "person_at", 2, person_at)
    put_fn(funcs, 5, "put", 4, put)
    put_fn(funcs, 6, "frame", 3, frame)
    put_fn(funcs, 7, "tick", 1, tick)
    put_fn(funcs, 8, "unread", 1, unread)
    var load_fn = load
    var unload_fn = unload
    var upgrade_fn = upgrade
    var load_bits = Pointer(to=load_fn).unsafe_bitcast[Int]()[]
    var unload_bits = Pointer(to=unload_fn).unsafe_bitcast[Int]()[]
    var upgrade_bits = Pointer(to=upgrade_fn).unsafe_bitcast[Int]()[]
    return make_entry(
        lit("Elixir.ZoneRelay.Nif"),
        funcs,
        c_int(9),
        callback_opt(load_bits),
        None,
        callback_opt(upgrade_bits),
        callback_opt(unload_bits),
    )
