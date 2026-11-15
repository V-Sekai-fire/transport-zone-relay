// Properties of the caps on what a zone saves (src/zone_caps.c), each beside a planted-false control. The model below is
// written from the numbers in docs/zone-caps.md and shares no code and no constant with zone_caps.h, so a wrong constant
// there is a disagreement here.
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "witness/doctest.h"
#include <cstring>
#include <functional>
#include <vector>
extern "C" {
#include "../src/zone_caps.h"
}

namespace {
struct Op {
	int owner = 0, kind = 0;
	uint32_t bytes = 0;
	int64_t dt = 0;
};
struct Case {
	std::vector<Op> ops;
};

// The doc's numbers, written out.
struct Model {
	uint32_t data[4] = { 0, 0, 0, 0 }, object[4] = { 0, 0, 0, 0 };
	uint64_t db = 0, day = 0;
	int64_t day_start = 0;
	int expect(int owner, int kind, uint32_t bytes, int64_t now) {
		if (kind == 3) { return 1; }
		if (kind < 0 || kind > 3) { return 2; }
		if (kind != 2 && (owner < 0 || owner > 3)) { return 3; }
		if (kind == 0 && static_cast<uint64_t>(data[owner]) + bytes > 100000) { return 4; }
		if (kind == 1 && static_cast<uint64_t>(object[owner]) + bytes > 100000) { return 4; }
		uint64_t after = db + bytes;
		if (after > 256ull * 4096ull) { return 5; }
		uint64_t used = day;
		int64_t start = day_start;
		if (now - start >= 86400) { used = 0; start = now; }
		if (after + used > 32ull * 1048576ull) { return 6; }
		if (kind == 0) { data[owner] += bytes; }
		if (kind == 1) { object[owner] += bytes; }
		db = after;
		day = used + after;
		day_start = start;
		return 0;
	}
};

uint32_t pick_bytes(witness::RNG &rng) {
	switch (rng.int_range(0, 6)) {
		case 0: return 0;
		case 1: return rng.uint_range(1, 5000);
		case 2: return rng.uint_range(60000, 100001);
		case 3: return 100000 - rng.uint_range(0, 3);
		case 4: return 1048576 - rng.uint_range(0, 4096);
		case 5: return rng.uint_range(0, 1100000);
		default: return rng.uint_range(0, 30);
	}
}
int64_t pick_dt(witness::RNG &rng) {
	static const int64_t DT[8] = { 0, 0, 0, 1, 2, 86399, 86400, 86401 };
	return DT[rng.int_range(0, 7)];
}
Case gen_mixed(witness::RNG &rng, const witness::Level &lvl) {
	Case c;
	uint32_t n = rng.uint_range(0, static_cast<uint32_t>(lvl.fin_bound / 2) + 4);
	for (uint32_t i = 0; i < n; ++i) {
		Op o;
		o.owner = rng.int_range(-1, 4);
		o.kind = rng.int_range(0, 4);
		o.bytes = pick_bytes(rng);
		o.dt = pick_dt(rng);
		c.ops.push_back(o);
	}
	return c;
}
// Fills the database, then saves again and again so that the day's bytes are reached.
Case gen_saturating(witness::RNG &rng, const witness::Level &) {
	Case c;
	Op fill;
	fill.kind = 2;
	fill.bytes = 1048576;
	c.ops.push_back(fill);
	uint32_t n = 28 + rng.uint_range(0, 12);
	for (uint32_t i = 0; i < n; ++i) {
		Op o;
		o.owner = rng.int_range(0, 3);
		o.kind = rng.int_range(0, 2);
		o.bytes = rng.int_range(0, 3) == 0 ? rng.uint_range(0, 3) : 0;
		o.dt = rng.int_range(0, 9) == 0 ? pick_dt(rng) : 0;
		c.ops.push_back(o);
	}
	return c;
}
bool same(const zc_t &a, const zc_t &b) { return std::memcmp(&a, &b, sizeof a) == 0; }

// Runs a case against the model and reports each verdict.
struct Run {
	bool agrees = true, refusal_keeps = true, bounded = true, pose_in = false;
	bool saw[7] = { false, false, false, false, false, false, false };
};
Run run(const Case &c) {
	Run r;
	zc_t z;
	zc_init(&z);
	Model m;
	int64_t now = 0;
	for (const Op &o : c.ops) {
		now += o.dt;
		zc_t before = z;
		int want = m.expect(o.owner, o.kind, o.bytes, now);
		int got = static_cast<int>(zc_admit(&z, o.owner, static_cast<zc_kind_t>(o.kind), o.bytes, now));
		if (got != want) { r.agrees = false; }
		if (got >= 0 && got < 7) { r.saw[got] = true; }
		if (got != 0 && !same(z, before)) { r.refusal_keeps = false; }
		if (got == 0 && o.kind == 3) { r.pose_in = true; }
		if (z.db_bytes > 1048576u || z.day_bytes > 33554432ull) { r.bounded = false; }
		for (int k = 0; k < 4; ++k) {
			if (z.data[k] > 100000u || z.object[k] > 100000u) { r.bounded = false; }
		}
	}
	return r;
}
} // namespace

TEST_CASE("[caps] every verdict equals the model written from the numbers of the doc") {
	witness::Generator<Case> mixed = &gen_mixed;
	witness::Generator<Case> sat = &gen_saturating;
	std::function<bool(const Case &)> pred = [](const Case &c) { return run(c).agrees; };
	witness::Trial a = witness::resolve<Case>("verdicts, mixed", mixed, pred);
	INFO(a.message);
	CHECK(a.outcome != witness::Outcome::FOUND);
	witness::Trial b = witness::resolve<Case>("verdicts, saturating", sat, pred);
	INFO(b.message);
	CHECK(b.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[caps] no sequence takes the database, a player or the day past its cap") {
	witness::Generator<Case> mixed = &gen_mixed;
	witness::Generator<Case> sat = &gen_saturating;
	std::function<bool(const Case &)> pred = [](const Case &c) { return run(c).bounded; };
	witness::Trial a = witness::resolve<Case>("bounded, mixed", mixed, pred);
	INFO(a.message);
	CHECK(a.outcome != witness::Outcome::FOUND);
	witness::Trial b = witness::resolve<Case>("bounded, saturating", sat, pred);
	INFO(b.message);
	CHECK(b.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[caps] a refusal leaves the state byte for byte, and a pose is never saved") {
	witness::Generator<Case> mixed = &gen_mixed;
	witness::Generator<Case> sat = &gen_saturating;
	std::function<bool(const Case &)> pred = [](const Case &c) {
		Run r = run(c);
		return r.refusal_keeps && !r.pose_in;
	};
	witness::Trial a = witness::resolve<Case>("refusals, mixed", mixed, pred);
	INFO(a.message);
	CHECK(a.outcome != witness::Outcome::FOUND);
	witness::Trial b = witness::resolve<Case>("refusals, saturating", sat, pred);
	INFO(b.message);
	CHECK(b.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[caps] a save is due one second after the last, and never inside it") {
	witness::Generator<Case> mixed = &gen_mixed;
	std::function<bool(const Case &)> pred = [](const Case &c) {
		zc_t z;
		zc_init(&z);
		int64_t now = 0;
		if (!zc_due(&z, now)) { return false; }
		for (const Op &o : c.ops) {
			now += o.dt;
			if (zc_admit(&z, o.owner, static_cast<zc_kind_t>(o.kind), o.bytes, now) == ZC_OK) {
				if (zc_due(&z, now) || !zc_due(&z, now + 1) || zc_due(&z, now + 0)) { return false; }
			}
		}
		return true;
	};
	witness::Trial t = witness::resolve<Case>("merge window", mixed, pred);
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[caps] falsifiability: every save being admitted is planted false and is caught") {
	witness::Generator<Case> mixed = &gen_mixed;
	std::function<bool(const Case &)> pred = [](const Case &c) {
		Run r = run(c);
		return r.saw[0] && !r.saw[1] && !r.saw[2] && !r.saw[3] && !r.saw[4] && !r.saw[5] && !r.saw[6];
	};
	witness::Trial t = witness::resolve<Case>("only OK", mixed, pred);
	INFO(t.message);
	CHECK(t.outcome == witness::Outcome::FOUND);
}

TEST_CASE("[caps] falsifiability: the generators reach every verdict, so the properties can fail on each") {
	witness::Generator<Case> mixed = &gen_mixed;
	witness::Generator<Case> sat = &gen_saturating;
	const char *names[7] = { "OK", "pose", "kind", "seat", "player full", "database full", "day full" };
	for (int v = 0; v < 7; ++v) {
		std::function<bool(const Case &)> pred = [v](const Case &c) { return !run(c).saw[v]; };
		witness::Trial t = witness::resolve<Case>(names[v], v == 6 ? sat : mixed, pred);
		INFO(names[v]);
		INFO(t.message);
		CHECK(t.outcome == witness::Outcome::FOUND);
	}
}
