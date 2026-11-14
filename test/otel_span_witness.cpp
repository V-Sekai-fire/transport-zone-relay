// Properties of the span emitter (src/otel_span.h), each beside a planted-false control. The emitter writes
// one format, so every property reads the protobuf back with a reader that shares no code with it.
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "witness/doctest.h"

#include <cstdio>
#include <cstring>
#include <functional>
#include <string>
#include <vector>
#include <unistd.h>

extern "C" {
#include "../src/otel_span.h"
}

namespace {

struct Item {
	int name = 0;
	bool child = false;
	int64_t t0 = 0, t1 = 0;
	uint32_t nattr = 0;
	int64_t val[OTEL_ATTRS] = {};
};

struct Case {
	std::vector<Item> items;
};

const char *const NAMES[4] = { "entity.tick", "entity.run", "relay.pass", "a.b" };
const char *const KEYS[OTEL_ATTRS] = { "clients", "packets_in", "datagrams_out", "tick", "k", "n" };

Case gen_case(witness::RNG &rng, const witness::Level &lvl) {
	Case c;
	uint32_t n = rng.uint_range(0, static_cast<uint32_t>(lvl.fin_bound / 8));
	for (uint32_t i = 0; i < n; ++i) {
		Item it;
		it.name = rng.int_range(0, 3);
		it.child = i > 0 && rng.int_range(0, 1) == 1;
		it.t0 = rng.int64_range(0, 4000000000000LL);
		it.t1 = it.t0 + rng.int64_range(0, 9000000);
		it.nattr = rng.uint_range(0, OTEL_ATTRS + 2);
		for (int k = 0; k < OTEL_ATTRS; ++k) {
			it.val[k] = rng.int64_range(-1000000000000LL, 1000000000000LL);
		}
		c.items.push_back(it);
	}
	return c;
}

otel_t *store() {
	static otel_t *o = new otel_t;
	return o;
}

// Runs the emitter on a case and returns the bytes it wrote in one flush.
std::string emit(const Case &c, std::vector<uint64_t> *ids, uint32_t *dropped, uint32_t *left) {
	otel_t *o = store();
	char path[] = "/tmp/otel_witness_XXXXXX";
	int fd = mkstemp(path);
	close(fd);
	otel_open(o, path, 7);
	for (const Item &it : c.items) {
		uint64_t parent = (it.child && ids && !ids->empty()) ? ids->back() : 0;
		int64_t vals[OTEL_ATTRS];
		for (int k = 0; k < OTEL_ATTRS; ++k) {
			vals[k] = it.val[k];
		}
		uint64_t sid = otel_span(o, NAMES[it.name], parent, it.t0, it.t1, it.nattr, KEYS, vals);
		if (ids) {
			ids->push_back(sid);
		}
	}
	otel_flush(o);
	if (dropped) {
		*dropped = o->dropped;
	}
	if (left) {
		*left = o->n;
	}
	otel_close(o);
	std::string text;
	if (FILE *f = fopen(path, "r")) {
		char buf[65536];
		size_t n;
		while ((n = fread(buf, 1, sizeof buf, f)) > 0) {
			text.append(buf, n);
		}
		fclose(f);
	}
	remove(path);
	return text;
}

struct PbSpan {
	std::string trace, sid, parent, name;
	uint64_t kind = 0, t0 = 0, t1 = 0;
	std::vector<std::pair<std::string, uint64_t>> attrs;
};

struct Rd {
	const uint8_t *p, *e;
	bool varint(uint64_t *v) {
		*v = 0;
		for (int sh = 0; p < e && sh < 70; sh += 7) {
			uint8_t b = *p++;
			*v |= static_cast<uint64_t>(b & 0x7F) << sh;
			if (!(b & 0x80)) {
				return true;
			}
		}
		return false;
	}
	bool bytes(std::string *s) {
		uint64_t n;
		if (!varint(&n) || n > static_cast<uint64_t>(e - p)) {
			return false;
		}
		s->assign(reinterpret_cast<const char *>(p), static_cast<size_t>(n));
		p += n;
		return true;
	}
	bool fixed(uint64_t *v) {
		if (e - p < 8) {
			return false;
		}
		*v = 0;
		for (int i = 0; i < 8; i++) {
			*v |= static_cast<uint64_t>(p[i]) << (8 * i);
		}
		p += 8;
		return true;
	}
};

bool dec_attr(const std::string &m, std::pair<std::string, uint64_t> *out) {
	Rd r{ reinterpret_cast<const uint8_t *>(m.data()), reinterpret_cast<const uint8_t *>(m.data()) + m.size() };
	while (r.p < r.e) {
		uint64_t tag;
		std::string s;
		if (!r.varint(&tag) || (tag & 7) != 2 || !r.bytes(&s)) {
			return false;
		}
		if (tag >> 3 == 1) {
			out->first = s;
		} else {
			Rd a{ reinterpret_cast<const uint8_t *>(s.data()), reinterpret_cast<const uint8_t *>(s.data()) + s.size() };
			uint64_t t, v;
			if (!a.varint(&t) || t != 0x18 || !a.varint(&v) || a.p != a.e) {
				return false;
			}
			out->second = v;
		}
	}
	return true;
}

bool dec_span(const std::string &m, PbSpan *o) {
	Rd r{ reinterpret_cast<const uint8_t *>(m.data()), reinterpret_cast<const uint8_t *>(m.data()) + m.size() };
	while (r.p < r.e) {
		uint64_t tag, v;
		std::string s;
		if (!r.varint(&tag)) {
			return false;
		}
		switch (tag) {
			case 0x0A: if (!r.bytes(&o->trace)) return false; break;
			case 0x12: if (!r.bytes(&o->sid)) return false; break;
			case 0x22: if (!r.bytes(&o->parent)) return false; break;
			case 0x2A: if (!r.bytes(&o->name)) return false; break;
			case 0x30: if (!r.varint(&o->kind)) return false; break;
			case 0x39: if (!r.fixed(&o->t0)) return false; break;
			case 0x41: if (!r.fixed(&o->t1)) return false; break;
			case 0x4A: {
				std::pair<std::string, uint64_t> kv;
				if (!r.bytes(&s) || !dec_attr(s, &kv)) return false;
				o->attrs.push_back(kv);
				break;
			}
			default: (void)v; return false;
		}
	}
	return true;
}

// Reads every record; false if any byte is left over or malformed.
bool dec_all(const std::string &t, std::vector<PbSpan> *out) {
	size_t at = 0;
	while (at < t.size()) {
		if (t.size() - at < 4) {
			return false;
		}
		uint32_t len = static_cast<uint8_t>(t[at]) | static_cast<uint8_t>(t[at + 1]) << 8 | static_cast<uint8_t>(t[at + 2]) << 16 | static_cast<uint32_t>(static_cast<uint8_t>(t[at + 3])) << 24;
		at += 4;
		if (len > t.size() - at) {
			return false;
		}
		Rd r{ reinterpret_cast<const uint8_t *>(t.data()) + at, reinterpret_cast<const uint8_t *>(t.data()) + at + len };
		at += len;
		bool scoped = false;
		while (r.p < r.e) {
			uint64_t tag;
			std::string s;
			if (!r.varint(&tag) || (tag & 7) != 2 || !r.bytes(&s)) {
				return false;
			}
			if (tag == 0x0A) {
				scoped = s == "\x0A\x0D" "entity-server";
			} else if (tag == 0x12) {
				PbSpan sp;
				if (!dec_span(s, &sp)) {
					return false;
				}
				out->push_back(sp);
			} else {
				return false;
			}
		}
		if (!scoped) {
			return false;
		}
	}
	return true;
}

} // namespace

TEST_CASE("[otel] span ids are never zero and never repeat within a trace") {
	witness::Generator<Case> gen = &gen_case;
	std::function<bool(const Case &)> pred = [](const Case &c) {
		std::vector<uint64_t> ids;
		std::string t = emit(c, &ids, nullptr, nullptr);
		std::vector<PbSpan> got;
		if (!dec_all(t, &got)) {
			return false;
		}
		std::vector<std::string> seen;
		for (const PbSpan &g : got) {
			if (g.sid == std::string(8, '\0')) {
				return false;
			}
			for (const std::string &x : seen) {
				if (x == g.sid) {
					return false;
				}
			}
			seen.push_back(g.sid);
		}
		return true;
	};
	witness::Trial t = witness::resolve<Case>("ids distinct", gen, pred);
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[otel] a full ring drops and counts, and a flush empties it") {
	witness::Generator<Case> gen = [](witness::RNG &rng, const witness::Level &) {
		Case c;
		c.items.resize(static_cast<uint32_t>(OTEL_CAP) - 8 + rng.uint_range(0, 16));
		return c;
	};
	std::function<bool(const Case &)> pred = [](const Case &c) {
		uint32_t dropped = 99, left = 99;
		std::string t = emit(c, nullptr, &dropped, &left);
		std::vector<PbSpan> got;
		size_t n = c.items.size();
		return dec_all(t, &got) && dropped == (n > OTEL_CAP ? n - OTEL_CAP : 0) && left == 0 && got.size() == (n < OTEL_CAP ? n : OTEL_CAP);
	};
	witness::Trial t = witness::resolve<Case>("ring bounds", gen, pred);
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[otel] falsifiability: a flush that leaves spans queued is planted false and is caught") {
	witness::Generator<Case> gen = &gen_case;
	std::function<bool(const Case &)> pred = [](const Case &c) {
		uint32_t left = 0;
		emit(c, nullptr, nullptr, &left);
		return left != 0 || c.items.empty();
	};
	witness::Trial t = witness::resolve<Case>("flush leaves spans", gen, pred);
	INFO(t.message);
	CHECK(t.outcome == witness::Outcome::FOUND);
}

TEST_CASE("[otel] the protobuf records decode to the spans that were recorded") {
	witness::Generator<Case> gen = &gen_case;
	std::function<bool(const Case &)> pred = [](const Case &c) {
		std::vector<uint64_t> ids;
		std::string t = emit(c, &ids, nullptr, nullptr);
		std::vector<PbSpan> got;
		if (!dec_all(t, &got)) {
			return false;
		}
		size_t want = c.items.size() < OTEL_CAP ? c.items.size() : OTEL_CAP;
		if (got.size() != want) {
			return false;
		}
		int64_t off = store()->wall_off;
		for (size_t i = 0; i < want; ++i) {
			const Item &it = c.items[i];
			const PbSpan &g = got[i];
			uint8_t id[8];
			otel_pb_be(id, ids[i]);
			bool root = !(it.child && i > 0);
			uint8_t pid[8] = {};
			if (!root) {
				otel_pb_be(pid, ids[i - 1]);
			}
			uint32_t na = it.nattr > OTEL_ATTRS ? OTEL_ATTRS : it.nattr;
			if (g.trace.size() != 16 || g.sid != std::string(reinterpret_cast<char *>(id), 8) || g.name != NAMES[it.name] || g.kind != 1 ||
					g.t0 != static_cast<uint64_t>(it.t0 + off) || g.t1 != static_cast<uint64_t>(it.t1 + off) || g.attrs.size() != na ||
					(root ? !g.parent.empty() : g.parent != std::string(reinterpret_cast<char *>(pid), 8)) || g.trace != got[0].trace) {
				return false;
			}
			for (uint32_t k = 0; k < na; ++k) {
				if (g.attrs[k].first != KEYS[k] || g.attrs[k].second != static_cast<uint64_t>(it.val[k])) {
					return false;
				}
			}
		}
		return true;
	};
	witness::Trial t = witness::resolve<Case>("protobuf roundtrip", gen, pred);
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[otel] falsifiability: protobuf output being empty is planted false and is caught") {
	witness::Generator<Case> gen = &gen_case;
	std::function<bool(const Case &)> pred = [](const Case &c) { return emit(c, nullptr, nullptr, nullptr).empty(); };
	witness::Trial t = witness::resolve<Case>("pb is empty", gen, pred);
	INFO(t.message);
	CHECK(t.outcome == witness::Outcome::FOUND);
}
