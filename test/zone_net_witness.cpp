// Properties of the relay on sockets (src/zone_net.c), each beside a planted build that must fail. A case starts the relay on
// loopback, seats between 2 and 8 clients one after another by a frame on the first half, and then has each send a second frame on the first half and one on the second. Every datagram a client
// gets is checked against what the doc says it must get, and the set of datagrams must equal the expected set: nothing from
// itself, nothing from another zone, nothing on the wrong half, nothing twice, and nothing missing. A case takes a second or
// less of the wall clock, so the ladder is short.
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "witness/doctest.h"
#include <arpa/inet.h>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <functional>
#include <map>
#include <netinet/in.h>
#include <set>
#include <sys/socket.h>
#include <thread>
#include <tuple>
#include <unistd.h>
#include <vector>
extern "C" {
#include "../src/zone_net.h"
}

namespace {
struct Case {
	int clients = 2;
};
typedef std::chrono::steady_clock Clock;

std::vector<uint8_t> frame(int id, int half, int seq) {
	std::vector<uint8_t> f(1200);
	for (size_t i = 0; i < f.size(); ++i) { f[i] = static_cast<uint8_t>(id * 16 + seq * 5 + static_cast<int>(i)); }
	f[0] = static_cast<uint8_t>(id);
	f[1] = static_cast<uint8_t>(half);
	f[2] = static_cast<uint8_t>(seq);
	return f;
}

Case gen_case(witness::RNG &rng, const witness::Level &) {
	Case c;
	c.clients = rng.int_range(2, 8);
	return c;
}

struct Outcome {
	bool exact = false, counts = false, rc = false;
};

Outcome play(const Case &c) {
	static int served = 0;
	const uint16_t base = static_cast<uint16_t>(20000 + (getpid() % 2000) * 16 + 2 * (served++ % 8));
	const int n = c.clients;
	const uint32_t ticks = static_cast<uint32_t>(5 * n + 24);
	zn_report_t rep;
	std::memset(&rep, 0, sizeof rep);
	int rc = -1;
	std::thread relay([&] { rc = zn_run("127.0.0.1", base, ticks, 0, &rep); });
	std::vector<int> fd(static_cast<size_t>(n));
	for (int i = 0; i < n; ++i) {
		fd[static_cast<size_t>(i)] = socket(AF_INET, SOCK_DGRAM, 0);
		struct sockaddr_in a;
		std::memset(&a, 0, sizeof a);
		a.sin_family = AF_INET;
		a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		bind(fd[static_cast<size_t>(i)], reinterpret_cast<struct sockaddr *>(&a), sizeof a);
		int big = 1 << 20;
		setsockopt(fd[static_cast<size_t>(i)], SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
	}
	const Clock::time_point t0 = Clock::now() + std::chrono::milliseconds(150);
	auto send = [&](int i, int half, int seq) {
		std::vector<uint8_t> f = frame(i + 1, half, seq);
		struct sockaddr_in to;
		std::memset(&to, 0, sizeof to);
		to.sin_family = AF_INET;
		to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		to.sin_port = htons(static_cast<uint16_t>(base + half));
		sendto(fd[static_cast<size_t>(i)], f.data(), f.size(), 0, reinterpret_cast<struct sockaddr *>(&to), sizeof to);
	};
	// Seated one after another, three ticks apart, by a frame on the first half. A tick takes the first half before the second, so
	// only the first half's socket, which keeps its order, may decide who joined before whom.
	for (int i = 0; i < n; ++i) {
		std::this_thread::sleep_until(t0 + std::chrono::milliseconds(47 * i));
		send(i, 0, 0);
	}
	const Clock::time_point t1 = t0 + std::chrono::milliseconds(47 * n + 60);
	for (int i = 0; i < n; ++i) {
		std::this_thread::sleep_until(t1 + std::chrono::milliseconds(12 * i));
		send(i, 0, 1);
		std::this_thread::sleep_for(std::chrono::milliseconds(2));
		send(i, 1, 1);
	}
	relay.join();
	// What each client got: (receiver, sender, half, seq), with the half taken from the port it came from.
	std::multiset<std::tuple<int, int, int, int>> got;
	bool bytes_ok = true;
	for (int j = 0; j < n; ++j) {
		for (;;) {
			uint8_t buf[2048];
			struct sockaddr_in from;
			socklen_t fl = sizeof from;
			ssize_t r = recvfrom(fd[static_cast<size_t>(j)], buf, sizeof buf, MSG_DONTWAIT, reinterpret_cast<struct sockaddr *>(&from), &fl);
			if (r < 0) { break; }
			int half = static_cast<int>(ntohs(from.sin_port)) - static_cast<int>(base);
			if (r != 1200 || buf[0] < 1 || buf[0] > 8 || (buf[1] != 0 && buf[1] != 1) || buf[2] > 1) {
				bytes_ok = false;
				continue;
			}
			int sender = buf[0] - 1, h = buf[1], seq = buf[2];
			std::vector<uint8_t> want = frame(sender + 1, h, seq);
			if (std::memcmp(buf, want.data(), 1200) != 0) { bytes_ok = false; }
			if (half != h) { bytes_ok = false; } // the half a frame names is the socket it came from
			got.insert(std::make_tuple(j, sender, h, seq));
		}
		close(fd[static_cast<size_t>(j)]);
	}
	// What the doc says they get: every frame sent after all were seated reaches every other member of the zone, and the first
	// frame of a member reaches the members who were seated before it. A zone is four members, in the order they were seated.
	std::multiset<std::tuple<int, int, int, int>> want;
	for (int j = 0; j < n; ++j) {
		for (int a = 0; a < n; ++a) {
			if (a == j || a / 4 != j / 4) { continue; }
			want.insert(std::make_tuple(j, a, 0, 1));
			want.insert(std::make_tuple(j, a, 1, 1));
			if (a > j) { want.insert(std::make_tuple(j, a, 0, 0)); }
		}
	}
	Outcome o;
	o.exact = bytes_ok && got == want;
	o.counts = rep.frames_in == static_cast<uint32_t>(3 * n) && rep.datagrams_out == want.size() && rep.refused == 0 && rep.strangers == 0 &&
			rep.send_failed == 0 && rep.people == static_cast<uint32_t>(n);
	o.rc = rc == 0;
	return o;
}

const witness::Level SHORT_LADDER[1] = { { 0, 0, 0, 5 } };

witness::Trial resolve_short(const char *name, std::function<bool(const Case &)> pred) {
	witness::Generator<Case> gen = &gen_case;
	witness::Shrinker<Case> none = &witness::no_shrink<Case>;
	std::function<void(std::ostream &, const Case &)> printer = [](std::ostream &os, const Case &c) { os << c.clients << " clients"; };
	return witness::resolve_with_ladder<Case>(name, SHORT_LADDER, gen, pred, none, printer);
}
} // namespace

TEST_CASE("[net] every client gets exactly the frames of the others in its zone, on the half they were sent on") {
	witness::Trial t = resolve_short("deliveries", [](const Case &c) { return play(c).exact; });
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[net] the relay counts what it took and what it sent, and refuses nothing it should take") {
	witness::Trial t = resolve_short("counts", [](const Case &c) {
		Outcome o = play(c);
		return o.counts && o.rc;
	});
	INFO(t.message);
	CHECK(t.outcome != witness::Outcome::FOUND);
}

TEST_CASE("[net] falsifiability: nobody ever getting a frame is planted false and is caught") {
	witness::Trial t = resolve_short("silence", [](const Case &c) {
		Outcome o = play(c);
		return !(o.exact && c.clients >= 2);
	});
	INFO(t.message);
	CHECK(t.outcome == witness::Outcome::FOUND);
}
