// Properties of the zone relay's state machine (src/zone_relay.c), each beside a planted-false control. The model is written
// from docs/zone-relay.md in terms of its numbers (4 slots, 1,200 and 1,472 bytes, one frame in 5 ticks with a burst of two,
// 192 silent ticks) and shares no code and no constant with zone_relay.h. The trace replay stays as the router model's record;
// these properties run the same machine on sequences nobody wrote down.
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "witness/doctest.h"
#include <cstring>
#include <functional>
#include <vector>
extern "C" {
#include "../src/zone_relay.h"
}

namespace {
struct Op {
	int kind = 0; // 0 join, 1 leave, 2 put, 3 ticks
	int a = 0, b = 0, c = 0;
};
struct Case {
	std::vector<Op> ops;
};

struct Model {
	int people[4] = { -1, -1, -1, -1 };
	uint64_t heard[4] = { 0, 0, 0, 0 }, due[8] = { 0, 0, 0, 0, 0, 0, 0, 0 }, now = 0, unread = 0;
	std::vector<uint8_t> store[8];
	size_t len[8];
	Model() {
		for (int s = 0; s < 4; ++s) { blank(s); }
	}
	void blank(int s) {
		for (int h = 0; h < 2; ++h) {
			store[s * 2 + h].assign(1472, 0);
			len[s * 2 + h] = 1200;
		}
	}
	int join(int p) {
		for (int s = 0; s < 4; ++s) {
			if (people[s] == p) { return s; }
		}
		for (int s = 0; s < 4; ++s) {
			if (people[s] == -1) {
				people[s] = p;
				heard[s] = now;
				return s;
			}
		}
		return -1;
	}
	int leave(int p) {
		for (int s = 0; s < 4; ++s) {
			if (people[s] == p) {
				people[s] = -1;
				blank(s);
				return 1;
			}
		}
		return 0;
	}
	int put(int slot, int half, const std::vector<uint8_t> &bytes) {
		if (slot < 0 || slot > 3 || half < 0 || half > 1) { return 0; }
		if (people[slot] == -1) { return 0; }
		int at = slot * 2 + half;
		if (now + 5 < due[at]) {
			unread++;
			return 0;
		}
		if (bytes.size() > 1472) { return 0; }
		due[at] = (due[at] > now ? due[at] : now) + 5;
		for (size_t i = 0; i < bytes.size(); ++i) { store[at][i] = bytes[i]; }
		len[at] = bytes.size();
		heard[slot] = now;
		return 1;
	}
	void tick() {
		now++;
		for (int s = 0; s < 4; ++s) {
			if (people[s] != -1 && now - heard[s] > 192) {
				people[s] = -1;
				blank(s);
			}
		}
	}
	// Frame k of 6 for a viewer, as the doc says: the two halves of each other slot, in slot order.
	bool frame(int viewer, int k, int *at) const {
		if (k < 0 || k > 5) { return false; }
		int v = viewer < 0 ? 0 : (viewer > 3 ? 3 : viewer);
		int other = k / 2;
		*at = (other >= v ? other + 1 : other) * 2 + k % 2;
		return true;
	}
};

std::vector<uint8_t> payload(int len, int fill, int at, bool tagged) {
	std::vector<uint8_t> b(static_cast<size_t>(len));
	for (int i = 0; i < len; ++i) { b[static_cast<size_t>(i)] = static_cast<uint8_t>(fill + i * 7); }
	if (tagged && len > 0) { b[0] = static_cast<uint8_t>(1 + at); }
	return b;
}

Case gen_case(witness::RNG &rng, const witness::Level &lvl) {
	Case c;
	uint32_t n = rng.uint_range(0, static_cast<uint32_t>(lvl.fin_bound / 3) + 6);
	for (uint32_t i = 0; i < n; ++i) {
		Op o;
		int r = rng.int_range(0, 9);
		if (r < 2) {
			o.kind = 0;
			o.a = rng.int_range(0, 5);
		} else if (r < 3) {
			o.kind = 1;
			o.a = rng.int_range(0, 5);
		} else if (r < 7) {
			o.kind = 2;
			o.a = rng.int_range(-1, 4);
			o.b = rng.int_range(-1, 2);
			int cls = rng.int_range(0, 5);
			o.c = cls == 0 ? 0 : cls == 1 ? 1200 : cls == 2 ? 1472 : cls == 3 ? 1473 : rng.int_range(1, 1400);
		} else {
			o.kind = 3;
			o.a = rng.int_range(0, 9) == 0 ? rng.int_range(150, 260) : rng.int_range(1, 8);
		}
		c.ops.push_back(o);
	}
	return c;
}

struct Result {
	bool agrees = true, never_own = true, unread_monotone = true;
};
// tagged: the first byte of a frame names the half it came from, so a viewer's own slot can be told by its tag alone.
Result run(const Case &c, bool tagged) {
	Result r;
	zr_zone_t z;
	zr_reset(&z);
	Model m;
	uint64_t last_unread = 0;
	for (const Op &o : c.ops) {
		if (o.kind == 0) {
			if (zr_join(&z, o.a) != m.join(o.a)) { r.agrees = false; }
		} else if (o.kind == 1) {
			if (zr_leave(&z, o.a) != m.leave(o.a)) { r.agrees = false; }
		} else if (o.kind == 2) {
			int at = o.a * 2 + o.b;
			std::vector<uint8_t> b = payload(o.c, o.a * 31 + o.b, at, tagged);
			int want = m.put(o.a, o.b, b);
			int got = zr_put(&z, o.a, o.b, b.data(), b.size());
			if (got != want) { r.agrees = false; }
		} else {
			for (int i = 0; i < o.a; ++i) {
				m.tick();
				zr_tick(&z);
			}
		}
		for (int s = 0; s < 4; ++s) {
			if (zr_person_at(&z, s) != m.people[s]) { r.agrees = false; }
		}
		if (zr_unread(&z) != m.unread) { r.agrees = false; }
		if (zr_unread(&z) < last_unread) { r.unread_monotone = false; }
		last_unread = zr_unread(&z);
		for (int viewer = -1; viewer <= 4; ++viewer) {
			for (int k = -1; k <= 6; ++k) {
				size_t len = 99;
				const uint8_t *p = zr_frame(&z, viewer, k, &len);
				int at = 0;
				bool ok = m.frame(viewer, k, &at);
				if (!ok) {
					if (p != nullptr || len != 0) { r.agrees = false; }
					continue;
				}
				if (p == nullptr || len != m.len[at] || std::memcmp(p, m.store[at].data(), len) != 0) { r.agrees = false; }
				if (tagged && viewer >= 0 && viewer <= 3 && len > 0 && p[0] != 0 && (p[0] - 1) / 2 == viewer) { r.never_own = false; }
			}
		}
	}
	return r;
}
} // namespace

TEST_CASE("[relay] every answer equals the model written from the doc, over joins, leaves, puts and ticks") {
	witness::Generator<Case> gen = &gen_case;
	std::function<bool(const Case &)> pred = [](const Case &c) { return run(c, false).agrees; };
	witness::Trial t = witness::resolve<Case>("relay equals model", gen, pred);
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[relay] a viewer is never handed a frame of its own slot, and the unread count only grows") {
	witness::Generator<Case> gen = &gen_case;
	std::function<bool(const Case &)> pred = [](const Case &c) {
		Result r = run(c, true);
		return r.never_own && r.unread_monotone;
	};
	witness::Trial t = witness::resolve<Case>("never own", gen, pred);
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[relay] a slot that is silent is emptied on the 193rd tick and not before, and a frame renews it") {
	witness::Generator<Case> gen = [](witness::RNG &rng, const witness::Level &) {
		Case c;
		Op o;
		o.a = rng.int_range(0, 300); // ticks before the join
		o.b = rng.int_range(-1, 191); // ticks after the join before a renewing frame, -1 for none
		o.c = rng.int_range(0, 3);    // slot to join in, by seating others first
		c.ops.push_back(o);
		return c;
	};
	std::function<bool(const Case &)> pred = [](const Case &c) {
		const Op &o = c.ops[0];
		zr_zone_t z;
		zr_reset(&z);
		for (int i = 0; i < o.a; ++i) { zr_tick(&z); }
		for (int i = 0; i < o.c; ++i) { zr_join(&z, 100 + i); }
		int slot = zr_join(&z, 7);
		if (slot != o.c) { return false; }
		if (o.b >= 0) {
			for (int i = 0; i < o.b; ++i) { zr_tick(&z); }
			uint8_t one = 1;
			if (!zr_put(&z, slot, 0, &one, 1)) { return false; }
		}
		for (int i = 0; i < 192; ++i) {
			zr_tick(&z);
			if (zr_person_at(&z, slot) != 7) { return false; }
		}
		zr_tick(&z);
		return zr_person_at(&z, slot) == -1;
	};
	witness::Trial t = witness::resolve<Case>("silence", gen, pred);
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[relay] a half takes a burst of two frames, refuses the third, and takes one more after five ticks") {
	witness::Generator<Case> gen = [](witness::RNG &rng, const witness::Level &) {
		Case c;
		Op o;
		o.a = rng.int_range(0, 40);
		o.b = rng.int_range(0, 1);
		o.c = rng.int_range(0, 3);
		c.ops.push_back(o);
		return c;
	};
	std::function<bool(const Case &)> pred = [](const Case &c) {
		const Op &o = c.ops[0];
		zr_zone_t z;
		zr_reset(&z);
		for (int i = 0; i < o.c; ++i) { zr_join(&z, 100 + i); }
		int slot = zr_join(&z, 7);
		for (int i = 0; i < o.a; ++i) { zr_tick(&z); }
		uint8_t one = 1;
		if (!zr_put(&z, slot, o.b, &one, 1) || !zr_put(&z, slot, o.b, &one, 1)) { return false; }
		if (zr_put(&z, slot, o.b, &one, 1) || zr_unread(&z) != 1) { return false; }
		for (int i = 0; i < 4; ++i) { zr_tick(&z); }
		if (zr_put(&z, slot, o.b, &one, 1)) { return false; }
		zr_tick(&z);
		return zr_put(&z, slot, o.b, &one, 1) == 1;
	};
	witness::Trial t = witness::resolve<Case>("burst", gen, pred);
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[relay] a leave blanks both frames of the slot for every viewer") {
	witness::Generator<Case> gen = &gen_case;
	std::function<bool(const Case &)> pred = [](const Case &c) {
		zr_zone_t z;
		zr_reset(&z);
		for (const Op &o : c.ops) {
			if (o.kind == 0) { zr_join(&z, o.a); }
			if (o.kind == 2 && o.c <= 1472) {
				std::vector<uint8_t> b = payload(o.c, 9, 0, false);
				zr_put(&z, o.a, o.b, b.data(), b.size());
			}
			if (o.kind == 3) {
				for (int i = 0; i < o.a; ++i) { zr_tick(&z); }
			}
			if (o.kind == 1 && zr_leave(&z, o.a)) {
				for (int viewer = 0; viewer < 4; ++viewer) {
					for (int k = 0; k < 6; ++k) {
						size_t len = 0;
						const uint8_t *p = zr_frame(&z, viewer, k, &len);
						int slot = ((k / 2) >= viewer ? k / 2 + 1 : k / 2);
						if (zr_person_at(&z, slot) != -1) { continue; }
						if (len != 1200) { return false; }
						for (size_t i = 0; i < len; ++i) {
							if (p[i] != 0) { return false; }
						}
					}
				}
			}
		}
		return true;
	};
	witness::Trial t = witness::resolve<Case>("leave blanks", gen, pred);
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[relay] falsifiability: no frame ever being refused is planted false and is caught") {
	witness::Generator<Case> gen = &gen_case;
	std::function<bool(const Case &)> pred = [](const Case &c) {
		zr_zone_t z;
		zr_reset(&z);
		for (const Op &o : c.ops) {
			if (o.kind == 0) { zr_join(&z, o.a); }
			if (o.kind == 2 && o.c <= 1472) {
				std::vector<uint8_t> b = payload(o.c, 1, 0, false);
				zr_put(&z, o.a, o.b, b.data(), b.size());
			}
			if (o.kind == 3) {
				for (int i = 0; i < o.a; ++i) { zr_tick(&z); }
			}
		}
		return zr_unread(&z) == 0;
	};
	witness::Trial t = witness::resolve<Case>("nothing is refused", gen, pred);
	INFO(t.message);
	CHECK(t.outcome == witness::Outcome::FOUND);
}

TEST_CASE("[relay] falsifiability: a slot never being emptied by silence is planted false and is caught") {
	witness::Generator<Case> gen = &gen_case;
	std::function<bool(const Case &)> pred = [](const Case &c) {
		zr_zone_t z;
		zr_reset(&z);
		int joined = 0, seated_end = 0;
		for (const Op &o : c.ops) {
			if (o.kind == 0 && zr_join(&z, o.a) >= 0) { joined++; }
			if (o.kind == 3) {
				for (int i = 0; i < o.a; ++i) { zr_tick(&z); }
			}
		}
		for (int s = 0; s < 4; ++s) {
			if (zr_person_at(&z, s) != -1) { seated_end++; }
		}
		return joined == seated_end;
	};
	witness::Trial t = witness::resolve<Case>("nobody is emptied", gen, pred);
	INFO(t.message);
	CHECK(t.outcome == witness::Outcome::FOUND);
}
