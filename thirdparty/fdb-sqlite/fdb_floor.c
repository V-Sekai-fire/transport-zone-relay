// FoundationDB alone under game_load's player shape: N threads at H Hz, each tick one get,
// one set and a commit on a key of its own, latency from the tick's due time. No SQLite and
// no store: the floor game_load's players sit on, on the same host.
//
//   fdb_floor [--players N] [--hz H] [--seconds S] [--warmup S]
// SPDX-License-Identifier: Apache-2.0
#define _POSIX_C_SOURCE 200809L
#include <fdb_c.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static FDBDatabase *g_db;
static int g_players = 16;
static double g_hz = 20, g_seconds = 600, g_warmup = 5;

static uint64_t now_us(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

static void sleep_until(uint64_t t) {
	uint64_t n = now_us();
	if (t <= n) return;
	struct timespec d = {(time_t)((t - n) / 1000000), (long)((t - n) % 1000000) * 1000};
	nanosleep(&d, NULL);
}

static int cmp(const void *a, const void *b) {
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return x < y ? -1 : x > y;
}

static void *net(void *x) {
	(void)x;
	fdb_run_network();
	return NULL;
}

static fdb_error_t wait_f(FDBFuture *f) {
	fdb_error_t e = fdb_future_block_until_ready(f);
	if (!e) e = fdb_future_get_error(f);
	return e;
}

struct player {
	int id;
	uint64_t start, from, end;
	uint64_t *lat;
	size_t n;
};

static void *player(void *x) {
	struct player *p = x;
	const double period = 1e6 / g_hz;
	char key[64], val[100];
	memset(val, 'v', sizeof val);
	for (uint64_t i = 0;; i++) {
		uint64_t due = p->start + (uint64_t)(period * p->id / g_players) + (uint64_t)(period * i);
		if (due >= p->end) break;
		sleep_until(due);
		int klen = snprintf(key, sizeof key, "weft/floor/%d/%d", p->id, (int)(i % 1000));
		FDBTransaction *tr;
		if (fdb_database_create_transaction(g_db, &tr)) exit(1);
		for (;;) {
			FDBFuture *g = fdb_transaction_get(tr, (const uint8_t *)key, klen, 0);
			fdb_error_t e = wait_f(g);
			fdb_future_destroy(g);
			if (!e) {
				fdb_transaction_set(tr, (const uint8_t *)key, klen, (const uint8_t *)val, 100);
				FDBFuture *c = fdb_transaction_commit(tr);
				e = wait_f(c);
				fdb_future_destroy(c);
			}
			if (!e) break;
			FDBFuture *o = fdb_transaction_on_error(tr, e);
			e = wait_f(o);
			fdb_future_destroy(o);
			if (e) exit(1);
		}
		fdb_transaction_destroy(tr);
		if (due >= p->from) p->lat[p->n++] = now_us() - due;
	}
	return NULL;
}

int main(int argc, char **argv) {
	for (int a = 1; a + 1 < argc; a += 2) {
		if (!strcmp(argv[a], "--players")) g_players = atoi(argv[a + 1]);
		else if (!strcmp(argv[a], "--hz")) g_hz = atof(argv[a + 1]);
		else if (!strcmp(argv[a], "--seconds")) g_seconds = atof(argv[a + 1]);
		else if (!strcmp(argv[a], "--warmup")) g_warmup = atof(argv[a + 1]);
		else return 2;
	}
	if (fdb_select_api_version(FDB_API_VERSION) || fdb_setup_network()) return 1;
	pthread_t nt;
	pthread_create(&nt, NULL, net, NULL);
	if (fdb_create_database(getenv("WEFT_FDB_CLUSTER_FILE"), &g_db)) return 1;
	struct player *p = calloc((size_t)g_players, sizeof *p);
	pthread_t *th = calloc((size_t)g_players, sizeof *th);
	const uint64_t start = now_us() + 500000, from = start + (uint64_t)(g_warmup * 1e6);
	const uint64_t end = from + (uint64_t)(g_seconds * 1e6);
	const size_t cap = (size_t)(g_hz * (g_seconds + 1)) + 16;
	for (int i = 0; i < g_players; i++) {
		p[i] = (struct player){i, start, from, end, calloc(cap, sizeof(uint64_t)), 0};
		pthread_create(&th[i], NULL, player, &p[i]);
	}
	size_t total = 0;
	for (int i = 0; i < g_players; i++) {
		pthread_join(th[i], NULL);
		total += p[i].n;
	}
	uint64_t *all = calloc(total ? total : 1, sizeof *all);
	size_t k = 0;
	for (int i = 0; i < g_players; i++)
		for (size_t j = 0; j < p[i].n; j++) all[k++] = p[i].lat[j];
	qsort(all, k, sizeof *all, cmp);
	if (k == 0) return 1;
#define AT(q) (unsigned long)all[(size_t)((q) * (double)(k - 1))]
	printf("[FLOOR] count=%zu p50=%lu p99=%lu p999=%lu p9999=%lu p99999=%lu max=%lu\n", k,
	       AT(0.5), AT(0.99), AT(0.999), AT(0.9999), AT(0.99999), (unsigned long)all[k - 1]);
	size_t over = 0;
	for (size_t i = 0; i < k; i++) over += all[i] > 1000000;
	printf("[FLOOR] over_1000ms=%zu (%.1f per player-day)\n", over,
	       (double)over / ((double)k / (g_hz * 86400.0)));
	fdb_stop_network();
	pthread_join(nt, NULL);
	return 0;
}
