from witness.ladder import *


def gen_ints(mut r: Run, lvl: Level) -> List[Int]:
    return gen_list[Int](r, lvl, gen_int)


def show_ints(v: List[Int]) -> String:
    var s = String("[")
    for i in range(len(v)):
        if i > 0:
            s += ", "
        s += String(v[i])
    return s + "]"


def reverse_twice(v: List[Int], mut r: Run) -> Bool:
    var a = List[Int]()
    for i in range(len(v) - 1, -1, -1):
        a.append(v[i])
    var b = List[Int]()
    for i in range(len(a) - 1, -1, -1):
        b.append(a[i])
    for i in range(len(v)):
        if b[i] != v[i]:
            return False
    return True


def always_empty(v: List[Int], mut r: Run) -> Bool:
    return len(v) == 0


def main() raises:
    var t = resolve[List[Int]]("involution", gen_ints, reverse_twice, shrink_list[Int], show_ints)
    print(t.message)
    var c = resolve[List[Int]]("vectors are always empty", gen_ints, always_empty, shrink_list[Int], show_ints, 0xC0FFEE)
    print(c.message)
