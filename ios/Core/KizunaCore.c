/*
 * Kizuna for iOS/iPadOS - C shim over the chiaki-ng protocol library.
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (C) 2026 Kizuna contributors
 * Portions adapted from TP Play (ios/TPPlay/Platform/Core/TPPlayCore.c,
 * AGPL-3.0, Copyright (C) TP Play contributors) and from Akira
 * (source/core/host.cpp: registerHostAuto / connectHolepunch, AGPL-3.0,
 * Copyright (C) Akira contributors). chiaki-ng is
 * LicenseRef-AGPL-3.0-only-OpenSSL, Copyright (C) chiaki-ng contributors.
 *
 * This file is compiled by ios/Core/CMakeLists.txt inside the same CMake build
 * as chiaki-lib, with chiaki-lib's compile definitions, so the chiaki struct
 * layouts used here are exactly the ones the library was built with.
 * Swift never sees any chiaki type: see KizunaCore.h.
 */

#include "KizunaCore.h"

#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <chiaki/config.h>
#include <chiaki/common.h>
#include <chiaki/log.h>
#include <chiaki/base64.h>
#include <chiaki/controller.h>
#include <chiaki/orientation.h>
#include <chiaki/discovery.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/remote/holepunch.h>
#include <chiaki/remote/rudp.h>

#if !CHIAKI_LIB_ENABLE_OPUS
#error "Kizuna needs chiaki-lib built with CHIAKI_LIB_ENABLE_OPUS=ON"
#endif

/* CHIAKI_VERSION comes from chiaki's add_definitions(), which CMakeLists.txt
 * copies onto this target together with every other chiaki define. */
#ifdef CHIAKI_VERSION
#define KZ_CHIAKI_VERSION CHIAKI_VERSION
#else
#define KZ_CHIAKI_VERSION "unknown"
#endif

/* ======================================================================== */
/* Library, logging, helpers                                                */
/* ======================================================================== */

static pthread_once_t kz_init_once = PTHREAD_ONCE_INIT;
static int kz_init_error = CHIAKI_ERR_UNINITIALIZED;

static _Atomic(KZLogCallback) kz_log_callback = NULL;
static _Atomic(void *) kz_log_user = NULL;
static _Atomic(uint32_t) kz_log_mask = KZ_LOG_ERROR | KZ_LOG_WARNING | KZ_LOG_INFO;

static void kz_init_impl(void)
{
	kz_init_error = (int)chiaki_lib_init();
}

int kz_core_init(void)
{
	pthread_once(&kz_init_once, kz_init_impl);
	return kz_init_error;
}

void kz_core_set_log_callback(KZLogCallback callback, void *user)
{
	atomic_store(&kz_log_user, user);
	atomic_store(&kz_log_callback, callback);
}

void kz_core_set_log_mask(uint32_t mask)
{
	atomic_store(&kz_log_mask, mask);
}

const char *kz_core_version(void)
{
	return "Kizuna core 1.0.0 (chiaki-ng " KZ_CHIAKI_VERSION ")";
}

const char *kz_error_string(int code)
{
	return chiaki_error_string((ChiakiErrorCode)code);
}

const char *kz_quit_reason_string(int reason)
{
	if(reason == KZ_QUIT_CONNECT_FAILED)
		return "Connection failed";
	return chiaki_quit_reason_string((ChiakiQuitReason)reason);
}

bool kz_quit_reason_is_error(int reason)
{
	if(reason == KZ_QUIT_CONNECT_FAILED)
		return true;
	return chiaki_quit_reason_is_error((ChiakiQuitReason)reason);
}

static void kz_log_forward(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	KZLogCallback cb = atomic_load(&kz_log_callback);
	if(cb)
		cb((int)level, msg, atomic_load(&kz_log_user));
	else
		chiaki_log_cb_print(level, msg, NULL);
}

static void kz_log_init(ChiakiLog *log)
{
	chiaki_log_init(log, atomic_load(&kz_log_mask), kz_log_forward, NULL);
}

static char *kz_strdup(const char *s)
{
	if(!s)
		return NULL;
	size_t n = strlen(s) + 1;
	char *r = malloc(n);
	if(r)
		memcpy(r, s, n);
	return r;
}

static const char *kz_nz(const char *s)
{
	return s ? s : "";
}

static int kz_hex_value(char c)
{
	if(c >= '0' && c <= '9') return c - '0';
	if(c >= 'a' && c <= 'f') return c - 'a' + 10;
	if(c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

/* Parses exactly out_len bytes from 2*out_len hex characters. */
static bool kz_parse_hex(const char *hex, uint8_t *out, size_t out_len)
{
	if(!hex || strlen(hex) != out_len * 2)
		return false;
	for(size_t i = 0; i < out_len; i++)
	{
		int hi = kz_hex_value(hex[2 * i]);
		int lo = kz_hex_value(hex[2 * i + 1]);
		if(hi < 0 || lo < 0)
			return false;
		out[i] = (uint8_t)((hi << 4) | lo);
	}
	return true;
}

/* PSN account id = base64 of the 64-bit user id, little endian (8 bytes). */
static bool kz_decode_account_id(const char *b64, uint8_t out[KZ_PSN_ACCOUNT_ID_SIZE])
{
	if(!b64 || !*b64)
		return false;
	size_t size = KZ_PSN_ACCOUNT_ID_SIZE;
	ChiakiErrorCode err = chiaki_base64_decode(b64, strlen(b64), out, &size);
	return err == CHIAKI_ERR_SUCCESS && size == KZ_PSN_ACCOUNT_ID_SIZE;
}

/* Reads a flag that other threads only write while holding `mutex`. */
static bool kz_flag(pthread_mutex_t *mutex, const bool *flag)
{
	pthread_mutex_lock(mutex);
	bool v = *flag;
	pthread_mutex_unlock(mutex);
	return v;
}

static uint64_t kz_now_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

static void kz_abs_deadline(struct timespec *ts, uint64_t ms_from_now)
{
	clock_gettime(CLOCK_REALTIME, ts);
	uint64_t ns = (uint64_t)ts->tv_nsec + (ms_from_now % 1000) * 1000000ull;
	ts->tv_sec += (time_t)(ms_from_now / 1000 + ns / 1000000000ull);
	ts->tv_nsec = (long)(ns % 1000000000ull);
}

int kz_generate_client_duid(char *out, size_t out_size)
{
	if(!out || out_size < CHIAKI_DUID_STR_SIZE)
		return CHIAKI_ERR_BUF_TOO_SMALL;
	memset(out, 0, out_size);
	size_t size = out_size;
	return (int)chiaki_holepunch_generate_client_device_uid(out, &size);
}

/* ======================================================================== */
/* PSN holepunch (shared by registration and remote sessions)               */
/* ======================================================================== */

typedef void (*KZStageFn)(void *ctx, int stage);

/*
 * Port of Akira's Host::connectHolepunch(): runs the PSN negotiation up to and
 * including the CTRL hole. The session handle is published in *slot under
 * `mutex` so another thread can cancel it with chiaki_holepunch_main_thread_cancel().
 * On failure *slot is cleared and the handle finalized here; on success the
 * caller owns *slot.
 */
static ChiakiErrorCode kz_holepunch_connect(ChiakiLog *log, const char *token,
	const uint8_t duid[KZ_DUID_SIZE], bool ps5,
	pthread_mutex_t *mutex, ChiakiHolepunchSession *slot, const bool *cancel,
	KZStageFn stage, void *stage_ctx)
{
	const int max_attempts = 3;
	ChiakiErrorCode err = CHIAKI_ERR_UNKNOWN;
	ChiakiHolepunchConsoleType type = ps5 ? CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5 : CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS4;

	for(int attempt = 1; attempt <= max_attempts; attempt++)
	{
		ChiakiHolepunchSession hp = chiaki_holepunch_session_init(token, log);
		if(!hp)
		{
			CHIAKI_LOGE(log, "Kizuna: holepunch session init failed");
			return CHIAKI_ERR_UNKNOWN;
		}

		pthread_mutex_lock(mutex);
		if(*cancel)
		{
			pthread_mutex_unlock(mutex);
			chiaki_holepunch_session_fini(hp);
			return CHIAKI_ERR_CANCELED;
		}
		*slot = hp;
		pthread_mutex_unlock(mutex);

		if(stage)
			stage(stage_ctx, KZ_STAGE_PSN_SESSION);

		err = chiaki_holepunch_upnp_discover(hp);
		if(err != CHIAKI_ERR_SUCCESS)
			CHIAKI_LOGW(log, "Kizuna: UPnP discovery failed (non-fatal): %s", chiaki_error_string(err));

		err = chiaki_holepunch_session_create(hp);
		if(err == CHIAKI_ERR_SUCCESS && !kz_flag(mutex, cancel))
			err = holepunch_session_create_offer(hp);
		if(err == CHIAKI_ERR_SUCCESS && !kz_flag(mutex, cancel))
		{
			if(stage)
				stage(stage_ctx, KZ_STAGE_PSN_CONSOLE);
			err = chiaki_holepunch_session_start(hp, duid, type);
		}
		if(err == CHIAKI_ERR_SUCCESS && !kz_flag(mutex, cancel))
		{
			if(stage)
				stage(stage_ctx, KZ_STAGE_PSN_PUNCH);
			err = chiaki_holepunch_session_punch_hole(hp, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);
		}
		if(err == CHIAKI_ERR_SUCCESS && kz_flag(mutex, cancel))
			err = CHIAKI_ERR_CANCELED;

		if(err == CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGI(log, "Kizuna: CTRL hole punched (attempt %d)", attempt);
			return CHIAKI_ERR_SUCCESS;
		}

		CHIAKI_LOGE(log, "Kizuna: holepunch attempt %d/%d failed: %s", attempt, max_attempts, chiaki_error_string(err));

		pthread_mutex_lock(mutex);
		*slot = NULL;
		bool canceled = *cancel;
		pthread_mutex_unlock(mutex);
		chiaki_holepunch_session_fini(hp);

		if(canceled)
			return CHIAKI_ERR_CANCELED;
		/* Akira only retries when the console could not be reached in time. */
		if(err != CHIAKI_ERR_HOST_UNREACH || attempt == max_attempts)
			return err;

		/* Back off attempt*2 s, waking up every 100 ms to honour cancellation. */
		for(int i = 0; i < attempt * 20; i++)
		{
			if(kz_flag(mutex, cancel))
				return CHIAKI_ERR_CANCELED;
			usleep(100 * 1000);
		}
	}
	return err;
}

/* ======================================================================== */
/* Discovery                                                                */
/* ======================================================================== */

struct KZDiscovery
{
	ChiakiLog log;
	ChiakiDiscovery discovery;
	ChiakiDiscoveryThread thread;
	KZDiscoveryCallback callback;
	void *user;
	pthread_mutex_t send_mutex;
};

static void kz_discovery_cb(ChiakiDiscoveryHost *host, void *user)
{
	KZDiscovery *d = user;
	if(!d->callback || !host)
		return;

	KZDiscoveredHost out;
	memset(&out, 0, sizeof(out));
	switch(host->state)
	{
		case CHIAKI_DISCOVERY_HOST_STATE_READY: out.state = KZ_HOST_STATE_READY; break;
		case CHIAKI_DISCOVERY_HOST_STATE_STANDBY: out.state = KZ_HOST_STATE_STANDBY; break;
		default: out.state = KZ_HOST_STATE_UNKNOWN; break;
	}
	out.is_ps5 = chiaki_discovery_host_is_ps5(host)
		|| (host->host_type && strcmp(host->host_type, "PS5") == 0);
	/* chiaki_discovery_host_system_version_target() atoi()s system_version. */
	if(host->system_version)
		out.target = (int)chiaki_discovery_host_system_version_target(host);
	else
		out.target = out.is_ps5 ? KZ_TARGET_PS5_1 : KZ_TARGET_PS4_UNKNOWN;
	if(out.is_ps5 && out.target < KZ_TARGET_PS5_UNKNOWN)
		out.target = KZ_TARGET_PS5_1;
	out.request_port = host->host_request_port;
	out.address = kz_nz(host->host_addr);
	out.name = kz_nz(host->host_name);
	out.host_id = kz_nz(host->host_id);
	out.host_type = kz_nz(host->host_type);
	out.system_version = kz_nz(host->system_version);
	out.running_app_name = kz_nz(host->running_app_name);
	out.running_app_titleid = kz_nz(host->running_app_titleid);
	d->callback(&out, d->user);
}

KZDiscovery *kz_discovery_create(KZDiscoveryCallback callback, void *user, int *error_out)
{
	int err = kz_core_init();
	if(err != CHIAKI_ERR_SUCCESS)
	{
		if(error_out) *error_out = err;
		return NULL;
	}
	KZDiscovery *d = calloc(1, sizeof(*d));
	if(!d)
	{
		if(error_out) *error_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	d->callback = callback;
	d->user = user;
	pthread_mutex_init(&d->send_mutex, NULL);
	kz_log_init(&d->log);

	ChiakiErrorCode cerr = chiaki_discovery_init(&d->discovery, &d->log, AF_INET);
	if(cerr != CHIAKI_ERR_SUCCESS)
	{
		pthread_mutex_destroy(&d->send_mutex);
		free(d);
		if(error_out) *error_out = (int)cerr;
		return NULL;
	}
	cerr = chiaki_discovery_thread_start(&d->thread, &d->discovery, kz_discovery_cb, d);
	if(cerr != CHIAKI_ERR_SUCCESS)
	{
		chiaki_discovery_fini(&d->discovery);
		pthread_mutex_destroy(&d->send_mutex);
		free(d);
		if(error_out) *error_out = (int)cerr;
		return NULL;
	}
	if(error_out) *error_out = CHIAKI_ERR_SUCCESS;
	return d;
}

/*
 * One SRCH datagram. We format with chiaki_discovery_packet_fmt() and call
 * sendto() ourselves (exactly what chiaki_discovery_send() does on Apple
 * platforms, including the trailing NUL) so that a sweep over 254 hosts that
 * mostly do not exist does not flood the log with per-packet errors.
 */
static bool kz_discovery_send_srch(KZDiscovery *d, uint32_t ipv4_host_order, bool ps5)
{
	ChiakiDiscoveryPacket packet;
	memset(&packet, 0, sizeof(packet));
	packet.cmd = CHIAKI_DISCOVERY_CMD_SRCH;
	packet.protocol_version = ps5 ? CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5 : CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS4;

	char buf[512];
	int len = chiaki_discovery_packet_fmt(buf, sizeof(buf), &packet);
	if(len < 0 || (size_t)len >= sizeof(buf))
		return false;

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_len = sizeof(addr);
	addr.sin_family = AF_INET;
	addr.sin_port = htons(ps5 ? CHIAKI_DISCOVERY_PORT_PS5 : CHIAKI_DISCOVERY_PORT_PS4);
	addr.sin_addr.s_addr = htonl(ipv4_host_order);

	for(int tries = 0; tries < 3; tries++)
	{
		ssize_t r = sendto(d->discovery.socket, buf, (size_t)len + 1, 0, (struct sockaddr *)&addr, sizeof(addr));
		if(r >= 0)
			return true;
		if(errno != ENOBUFS && errno != EAGAIN)
			return false;
		usleep(3000);
	}
	return false;
}

static bool kz_skip_interface(const char *name)
{
	static const char *skip[] = { "lo", "pdp_ip", "utun", "ipsec", "awdl", "llw", "ap", "anpi", "gif", "stf" };
	if(!name)
		return true;
	for(size_t i = 0; i < sizeof(skip) / sizeof(skip[0]); i++)
	{
		if(strncmp(name, skip[i], strlen(skip[i])) == 0)
			return true;
	}
	return false;
}

int kz_discovery_sweep(KZDiscovery *d)
{
	if(!d)
		return -1;
	struct ifaddrs *ifap = NULL;
	if(getifaddrs(&ifap) != 0)
		return -1;

	uint32_t seen_nets[16];
	size_t seen_count = 0;
	int sent = 0;

	pthread_mutex_lock(&d->send_mutex);
	for(struct ifaddrs *a = ifap; a; a = a->ifa_next)
	{
		if(!a->ifa_addr || !a->ifa_netmask || a->ifa_addr->sa_family != AF_INET)
			continue;
		if(!(a->ifa_flags & IFF_UP) || (a->ifa_flags & IFF_LOOPBACK) || !(a->ifa_flags & IFF_RUNNING))
			continue;
		if(kz_skip_interface(a->ifa_name))
			continue;

		uint32_t ip = ntohl(((struct sockaddr_in *)a->ifa_addr)->sin_addr.s_addr);
		uint32_t mask = ntohl(((struct sockaddr_in *)a->ifa_netmask)->sin_addr.s_addr);
		if((ip >> 16) == 0xA9FE) /* 169.254/16 link-local */
			continue;
		/* Sweep at most a /24: bigger networks are clamped to our own /24. */
		if(mask < 0xFFFFFF00u)
			mask = 0xFFFFFF00u;
		uint32_t net = ip & mask;

		bool dup = false;
		for(size_t i = 0; i < seen_count; i++)
			if(seen_nets[i] == net)
				dup = true;
		if(dup)
			continue;
		if(seen_count < sizeof(seen_nets) / sizeof(seen_nets[0]))
			seen_nets[seen_count++] = net;

		uint32_t hosts = ~mask; /* 255 for a /24 */
		CHIAKI_LOGI(&d->log, "Kizuna: discovery sweep on %s (%u hosts)", a->ifa_name, hosts - 1);
		for(uint32_t h = 1; h < hosts; h++)
		{
			uint32_t target = net | h;
			if(target == ip)
				continue;
			if(kz_discovery_send_srch(d, target, true))
				sent++;
			if(kz_discovery_send_srch(d, target, false))
				sent++;
			/* Pace the burst a little so the Wi-Fi queue does not overflow. */
			if((h & 31) == 0)
				usleep(2000);
		}
	}
	pthread_mutex_unlock(&d->send_mutex);
	freeifaddrs(ifap);
	return sent;
}

int kz_discovery_probe(KZDiscovery *d, const char *address)
{
	if(!d || !address || !*address)
		return CHIAKI_ERR_INVALID_DATA;
	struct addrinfo hints;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_DGRAM;
	struct addrinfo *res = NULL;
	if(getaddrinfo(address, NULL, &hints, &res) != 0 || !res)
		return CHIAKI_ERR_PARSE_ADDR;
	uint32_t ip = ntohl(((struct sockaddr_in *)res->ai_addr)->sin_addr.s_addr);
	freeaddrinfo(res);

	pthread_mutex_lock(&d->send_mutex);
	bool a = kz_discovery_send_srch(d, ip, true);
	bool b = kz_discovery_send_srch(d, ip, false);
	pthread_mutex_unlock(&d->send_mutex);
	return (a || b) ? CHIAKI_ERR_SUCCESS : CHIAKI_ERR_NETWORK;
}

void kz_discovery_destroy(KZDiscovery *d)
{
	if(!d)
		return;
	chiaki_discovery_thread_stop(&d->thread);
	chiaki_discovery_fini(&d->discovery);
	pthread_mutex_destroy(&d->send_mutex);
	free(d);
}

int kz_wakeup(const char *address, const uint8_t *regist_key, bool ps5)
{
	if(!address || !*address || !regist_key)
		return CHIAKI_ERR_INVALID_DATA;
	int err = kz_core_init();
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	/* The regist key is an ASCII hex string (e.g. "1a2b3c4d") padded with NULs;
	 * the WAKEUP user-credential is that hex string read as a number. */
	char key[KZ_REGIST_KEY_SIZE + 1];
	memcpy(key, regist_key, KZ_REGIST_KEY_SIZE);
	key[KZ_REGIST_KEY_SIZE] = '\0';
	if(strlen(key) == 0)
		return CHIAKI_ERR_INVALID_DATA;
	uint64_t credential = strtoull(key, NULL, 16);

	ChiakiLog log;
	kz_log_init(&log);
	return (int)chiaki_discovery_wakeup(&log, NULL, address, credential, ps5);
}

/* ======================================================================== */
/* PSN device list                                                          */
/* ======================================================================== */

int kz_psn_list_devices(const char *access_token, bool ps5, KZPSNDeviceCallback callback, void *user)
{
	if(!access_token || !*access_token || !callback)
		return CHIAKI_ERR_INVALID_DATA;
	int err = kz_core_init();
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	ChiakiLog log;
	kz_log_init(&log);
	ChiakiHolepunchDeviceInfo *devices = NULL;
	size_t count = 0;
	ChiakiErrorCode cerr = chiaki_holepunch_list_devices(access_token,
		ps5 ? CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5 : CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS4,
		&devices, &count, &log);
	if(cerr != CHIAKI_ERR_SUCCESS)
		return (int)cerr;

	for(size_t i = 0; i < count; i++)
	{
		/* device_name is char[32] filled with strncpy: may lack the NUL. */
		char name[sizeof(devices[i].device_name) + 1];
		memcpy(name, devices[i].device_name, sizeof(devices[i].device_name));
		name[sizeof(name) - 1] = '\0';

		char duid_hex[KZ_DUID_SIZE * 2 + 1];
		for(size_t j = 0; j < KZ_DUID_SIZE; j++)
			snprintf(duid_hex + 2 * j, 3, "%02x", devices[i].device_uid[j]);
		duid_hex[KZ_DUID_SIZE * 2] = '\0';

		KZPSNDevice device;
		device.name = name;
		device.duid_hex = duid_hex;
		device.is_ps5 = devices[i].type == CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5;
		device.remoteplay_enabled = devices[i].remoteplay_enabled;
		callback(&device, user);
	}
	if(devices)
		chiaki_holepunch_free_device_list(&devices);
	return CHIAKI_ERR_SUCCESS;
}

/* ======================================================================== */
/* Registration                                                             */
/* ======================================================================== */

struct KZRegistration
{
	ChiakiLog log;
	pthread_mutex_t mutex;
	pthread_cond_t cond;
	pthread_t thread;
	bool thread_started;
	bool destroy_after_callback;
	bool callback_running;

	/* parameters */
	bool psn;
	char *address;
	int target;
	uint8_t account_id[KZ_PSN_ACCOUNT_ID_SIZE];
	uint32_t pin;
	char *access_token;
	uint8_t duid[KZ_DUID_SIZE];
	bool ps5;
	KZProgressCallback progress;
	KZRegistCallback callback;
	void *user;

	/* state, guarded by mutex */
	bool cancel;
	bool regist_running;
	bool event_received;
	int event_type;
	ChiakiRegisteredHost host;
	ChiakiRegist regist;
	ChiakiHolepunchSession holepunch;
	ChiakiRudp rudp;
	ChiakiHolepunchRegistInfo hinfo;
	char console_address[64];
	char error[256];
};

static void kz_regist_free(KZRegistration *r)
{
	pthread_mutex_destroy(&r->mutex);
	pthread_cond_destroy(&r->cond);
	free(r->address);
	free(r->access_token);
	free(r);
}

static void kz_regist_event_cb(ChiakiRegistEvent *event, void *user)
{
	KZRegistration *r = user;
	pthread_mutex_lock(&r->mutex);
	r->event_type = (int)event->type;
	if(event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host)
		r->host = *event->registered_host;
	r->event_received = true;
	pthread_cond_broadcast(&r->cond);
	pthread_mutex_unlock(&r->mutex);
}

static void kz_regist_stage(void *ctx, int stage)
{
	KZRegistration *r = ctx;
	if(r->progress)
		r->progress(stage, r->user);
}

static void *kz_regist_thread(void *arg)
{
	KZRegistration *r = arg;
	ChiakiErrorCode err = CHIAKI_ERR_SUCCESS;

	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.broadcast = false;
	info.psn_online_id = NULL;
	memcpy(info.psn_account_id, r->account_id, sizeof(info.psn_account_id));

	if(r->psn)
	{
		err = kz_holepunch_connect(&r->log, r->access_token, r->duid, r->ps5,
			&r->mutex, &r->holepunch, &r->cancel, kz_regist_stage, r);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			snprintf(r->error, sizeof(r->error), "PSN connection failed: %s", chiaki_error_string(err));
			goto finish;
		}
		chiaki_socket_t *ctrl_sock = chiaki_get_holepunch_sock(r->holepunch, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);
		if(!ctrl_sock)
		{
			snprintf(r->error, sizeof(r->error), "No control socket after holepunch");
			err = CHIAKI_ERR_UNKNOWN;
			goto finish;
		}
		r->rudp = chiaki_rudp_init(ctrl_sock, &r->log);
		if(!r->rudp)
		{
			snprintf(r->error, sizeof(r->error), "RUDP init failed");
			err = CHIAKI_ERR_UNKNOWN;
			goto finish;
		}
		r->hinfo = chiaki_get_regist_info(r->holepunch);
		char selected[64];
		memset(selected, 0, sizeof(selected)); /* >= INET6_ADDRSTRLEN */
		chiaki_get_ps_selected_addr(r->holepunch, selected);
		selected[sizeof(selected) - 1] = '\0';
		memcpy(r->console_address, selected, sizeof(r->console_address));

		info.target = r->ps5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
		info.host = NULL; /* must be NULL: chiaki_regist_fini() frees it */
		info.holepunch_info = &r->hinfo;
		info.rudp = r->rudp;
		info.pin = 0;
		info.console_pin = 0;
	}
	else
	{
		info.target = (ChiakiTarget)r->target;
		info.host = r->address; /* strdup'ed by chiaki_regist_start */
		info.holepunch_info = NULL;
		info.rudp = NULL;
		info.pin = r->pin;
		info.console_pin = 0;
		snprintf(r->console_address, sizeof(r->console_address), "%s", r->address);
	}

	kz_regist_stage(r, KZ_STAGE_REGIST);

	pthread_mutex_lock(&r->mutex);
	if(r->cancel)
	{
		pthread_mutex_unlock(&r->mutex);
		err = CHIAKI_ERR_CANCELED;
		goto finish;
	}
	err = chiaki_regist_start(&r->regist, &r->log, &info, kz_regist_event_cb, r);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		pthread_mutex_unlock(&r->mutex);
		snprintf(r->error, sizeof(r->error), "Registration could not start: %s", chiaki_error_string(err));
		goto finish;
	}
	r->regist_running = true;

	struct timespec deadline;
	kz_abs_deadline(&deadline, 30000);
	while(!r->event_received && !r->cancel)
	{
		if(pthread_cond_timedwait(&r->cond, &r->mutex, &deadline) == ETIMEDOUT)
			break;
	}
	if(!r->event_received)
	{
		if(!r->cancel)
			snprintf(r->error, sizeof(r->error), "The console did not answer in time");
		chiaki_regist_stop(&r->regist);
	}
	pthread_mutex_unlock(&r->mutex);

	/* Joins chiaki's regist thread; its callback takes r->mutex, so not held here. */
	chiaki_regist_fini(&r->regist);
	pthread_mutex_lock(&r->mutex);
	r->regist_running = false;
	pthread_mutex_unlock(&r->mutex);

finish:
	if(r->rudp)
	{
		chiaki_rudp_fini(r->rudp);
		r->rudp = NULL;
	}
	{
		pthread_mutex_lock(&r->mutex);
		ChiakiHolepunchSession hp = r->holepunch;
		r->holepunch = NULL;
		pthread_mutex_unlock(&r->mutex);
		if(hp)
			chiaki_holepunch_session_fini(hp);
	}

	int status;
	pthread_mutex_lock(&r->mutex);
	if(r->event_received && r->event_type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS)
		status = KZ_REGIST_SUCCESS;
	else if(r->cancel || err == CHIAKI_ERR_CANCELED
		|| (r->event_received && r->event_type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED))
		status = KZ_REGIST_CANCELED;
	else
	{
		status = KZ_REGIST_FAILED;
		if(!r->error[0])
			snprintf(r->error, sizeof(r->error), "The console rejected the registration (wrong PIN or account?)");
	}
	r->callback_running = true;
	pthread_mutex_unlock(&r->mutex);

	KZRegistResult result;
	memset(&result, 0, sizeof(result));
	char nickname[sizeof(r->host.server_nickname) + 1];
	if(status == KZ_REGIST_SUCCESS)
	{
		memcpy(nickname, r->host.server_nickname, sizeof(r->host.server_nickname));
		nickname[sizeof(nickname) - 1] = '\0';
		result.target = (int)r->host.target;
		result.regist_key = (const uint8_t *)r->host.rp_regist_key;
		result.rp_key = r->host.rp_key;
		result.rp_key_type = r->host.rp_key_type;
		result.server_mac = r->host.server_mac;
		result.server_nickname = nickname;
		result.console_address = r->console_address;
		result.console_pin = r->host.console_pin;
	}
	if(r->callback)
		r->callback(status, status == KZ_REGIST_SUCCESS ? &result : NULL,
			status == KZ_REGIST_SUCCESS ? "" : r->error, r->user);

	pthread_mutex_lock(&r->mutex);
	r->callback_running = false;
	bool self_destroy = r->destroy_after_callback;
	pthread_mutex_unlock(&r->mutex);
	if(self_destroy)
	{
		pthread_detach(pthread_self());
		kz_regist_free(r);
	}
	return NULL;
}

static KZRegistration *kz_regist_alloc(KZRegistCallback callback, void *user)
{
	KZRegistration *r = calloc(1, sizeof(*r));
	if(!r)
		return NULL;
	pthread_mutex_init(&r->mutex, NULL);
	pthread_cond_init(&r->cond, NULL);
	r->callback = callback;
	r->user = user;
	kz_log_init(&r->log);
	return r;
}

static KZRegistration *kz_regist_launch(KZRegistration *r, int *error_out)
{
	if(pthread_create(&r->thread, NULL, kz_regist_thread, r) != 0)
	{
		kz_regist_free(r);
		if(error_out) *error_out = CHIAKI_ERR_THREAD;
		return NULL;
	}
	r->thread_started = true;
	if(error_out) *error_out = CHIAKI_ERR_SUCCESS;
	return r;
}

KZRegistration *kz_regist_start_pin(const char *address, int target,
	const char *psn_account_id_b64, uint32_t pin,
	KZRegistCallback callback, void *user, int *error_out)
{
	int err = kz_core_init();
	if(err != CHIAKI_ERR_SUCCESS)
	{
		if(error_out) *error_out = err;
		return NULL;
	}
	if(!address || !*address || !callback)
	{
		if(error_out) *error_out = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	KZRegistration *r = kz_regist_alloc(callback, user);
	if(!r)
	{
		if(error_out) *error_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	if(!kz_decode_account_id(psn_account_id_b64, r->account_id))
	{
		kz_regist_free(r);
		if(error_out) *error_out = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	r->psn = false;
	r->address = kz_strdup(address);
	r->target = target;
	r->pin = pin;
	if(!r->address)
	{
		kz_regist_free(r);
		if(error_out) *error_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	return kz_regist_launch(r, error_out);
}

KZRegistration *kz_regist_start_psn(const char *access_token, const char *console_duid_hex,
	bool ps5, const char *psn_account_id_b64,
	KZProgressCallback progress, KZRegistCallback callback, void *user, int *error_out)
{
	int err = kz_core_init();
	if(err != CHIAKI_ERR_SUCCESS)
	{
		if(error_out) *error_out = err;
		return NULL;
	}
	if(!access_token || !*access_token || !callback)
	{
		if(error_out) *error_out = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	KZRegistration *r = kz_regist_alloc(callback, user);
	if(!r)
	{
		if(error_out) *error_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	if(!kz_decode_account_id(psn_account_id_b64, r->account_id)
		|| !kz_parse_hex(console_duid_hex, r->duid, sizeof(r->duid)))
	{
		kz_regist_free(r);
		if(error_out) *error_out = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	r->psn = true;
	r->ps5 = ps5;
	r->progress = progress;
	r->access_token = kz_strdup(access_token);
	if(!r->access_token)
	{
		kz_regist_free(r);
		if(error_out) *error_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	return kz_regist_launch(r, error_out);
}

void kz_regist_cancel(KZRegistration *r)
{
	if(!r)
		return;
	pthread_mutex_lock(&r->mutex);
	r->cancel = true;
	if(r->holepunch)
		chiaki_holepunch_main_thread_cancel(r->holepunch, true);
	if(r->regist_running)
		chiaki_regist_stop(&r->regist);
	pthread_cond_broadcast(&r->cond);
	pthread_mutex_unlock(&r->mutex);
}

void kz_regist_destroy(KZRegistration *r)
{
	if(!r)
		return;
	if(r->thread_started && pthread_equal(pthread_self(), r->thread))
	{
		/* Called from inside our own callback: the worker frees us afterwards. */
		pthread_mutex_lock(&r->mutex);
		r->destroy_after_callback = true;
		pthread_mutex_unlock(&r->mutex);
		return;
	}
	kz_regist_cancel(r);
	if(r->thread_started)
		pthread_join(r->thread, NULL);
	kz_regist_free(r);
}

/* ======================================================================== */
/* Streaming session                                                        */
/* ======================================================================== */

struct KZSession
{
	ChiakiLog log;
	ChiakiSession session;
	ChiakiOpusDecoder opus;
	KZSessionCallbacks cb;
	KZVideoConfig video;

	bool ps5;
	bool psn;
	char *address;
	uint8_t regist_key[KZ_REGIST_KEY_SIZE];
	uint8_t rp_key[KZ_RP_KEY_SIZE];
	char *access_token;
	uint8_t duid[KZ_DUID_SIZE];
	uint8_t account_id[KZ_PSN_ACCOUNT_ID_SIZE];

	/* lifecycle, guarded by mutex */
	pthread_mutex_t mutex;
	pthread_t connect_thread;
	bool connect_thread_started;
	bool stop_requested;
	bool session_inited;
	bool session_started;
	ChiakiHolepunchSession holepunch; /* owned here until chiaki_session_init() */

	/* input, guarded by input_mutex */
	pthread_mutex_t input_mutex;
	bool input_live;
	ChiakiControllerState input_state;
	int touch_ids[2];
	ChiakiOrientationTracker orient;
	ChiakiAccelNewZero accel_zero;
	atomic_bool orient_reset;   /* set by MOTION_RESET, applied in set_input */

	atomic_bool connected;
	atomic_uint_fast64_t frames_received;
	atomic_uint_fast64_t frames_lost;
	atomic_uint_fast64_t frames_recovered;
};

static void kz_emit(KZSession *s, int type, int code, const char *message)
{
	if(s->cb.event)
		s->cb.event(type, code, message, s->cb.user);
}

static void kz_session_event_cb(ChiakiEvent *event, void *user)
{
	KZSession *s = user;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			atomic_store(&s->connected, true);
			kz_emit(s, KZ_EVENT_CONNECTED, 0, NULL);
			break;
		case CHIAKI_EVENT_QUIT:
		{
			atomic_store(&s->connected, false);
			const char *msg = event->quit.reason_str ? event->quit.reason_str
				: chiaki_quit_reason_string(event->quit.reason);
			kz_emit(s, KZ_EVENT_QUIT, (int)event->quit.reason, msg);
			break;
		}
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			kz_emit(s, KZ_EVENT_LOGIN_PIN_REQUEST, event->login_pin_request.pin_incorrect ? 1 : 0, NULL);
			break;
		case CHIAKI_EVENT_HOLEPUNCH:
			kz_emit(s, KZ_EVENT_DATA_HOLEPUNCH, event->data_holepunch.finished ? 1 : 0, NULL);
			break;
		case CHIAKI_EVENT_NICKNAME_RECEIVED:
		{
			char nick[sizeof(event->server_nickname) + 1];
			memcpy(nick, event->server_nickname, sizeof(event->server_nickname));
			nick[sizeof(nick) - 1] = '\0';
			kz_emit(s, KZ_EVENT_NICKNAME, 0, nick);
			break;
		}
		case CHIAKI_EVENT_RUMBLE:
			if(s->cb.rumble)
				s->cb.rumble(event->rumble.left, event->rumble.right, s->cb.user);
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
			if(s->cb.triggers)
				s->cb.triggers(event->trigger_effects.type_left, event->trigger_effects.left,
					event->trigger_effects.type_right, event->trigger_effects.right, s->cb.user);
			break;
		case CHIAKI_EVENT_MOTION_RESET:
			/* Do not take input_mutex on a chiaki thread (lock order with
			 * chiaki's feedback sender mutex); set_input applies the reset. */
			atomic_store(&s->orient_reset, true);
			kz_emit(s, KZ_EVENT_MOTION_RESET, 0, NULL);
			break;
		case CHIAKI_EVENT_LED_COLOR:
			kz_emit(s, KZ_EVENT_LED_COLOR,
				((int)event->led_state[0] << 16) | ((int)event->led_state[1] << 8) | (int)event->led_state[2], NULL);
			break;
		case CHIAKI_EVENT_PLAYER_INDEX:
			kz_emit(s, KZ_EVENT_PLAYER_INDEX, (int)event->player_index, NULL);
			break;
		case CHIAKI_EVENT_HAPTIC_INTENSITY:
			kz_emit(s, KZ_EVENT_HAPTIC_INTENSITY, (int)event->intensity, NULL);
			break;
		case CHIAKI_EVENT_TRIGGER_INTENSITY:
			kz_emit(s, KZ_EVENT_TRIGGER_INTENSITY, (int)event->intensity, NULL);
			break;
		default:
			/* keyboard, regist (auto_regist is off), FEC failure: not used */
			break;
	}
}

static bool kz_session_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	KZSession *s = user;
	atomic_fetch_add(&s->frames_received, 1);
	if(frames_lost > 0)
		atomic_fetch_add(&s->frames_lost, (uint_fast64_t)frames_lost);
	if(frame_recovered)
		atomic_fetch_add(&s->frames_recovered, 1);
	if(!s->cb.video)
		return true;
	return s->cb.video(buf, buf_size, frames_lost, frame_recovered, s->cb.user);
}

static void kz_audio_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	KZSession *s = user;
	if(s->cb.audio_settings)
		s->cb.audio_settings(channels, rate, s->cb.user);
}

static void kz_audio_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
	KZSession *s = user;
	/* opus_decode() returns samples per channel. */
	if(s->cb.audio_frame)
		s->cb.audio_frame(buf, samples_count, s->opus.audio_header.channels, s->cb.user);
}

static void kz_haptics_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
	KZSession *s = user;
	if(!s->cb.haptics || buf_size < 4 || (buf_size % 4) != 0)
		return;
	/* Copy into an aligned buffer: the packet payload is not int16 aligned. */
	int16_t pcm[512];
	size_t frames = buf_size / 4;
	if(frames > 256)
		frames = 256;
	memcpy(pcm, buf, frames * 4);
	s->cb.haptics(pcm, frames, s->cb.user);
}

static void kz_session_stage(void *ctx, int stage)
{
	kz_emit((KZSession *)ctx, KZ_EVENT_PROGRESS, stage, NULL);
}

static ChiakiVideoResolutionPreset kz_resolution_preset(int resolution)
{
	if(resolution >= 1080) return CHIAKI_VIDEO_RESOLUTION_PRESET_1080p;
	if(resolution >= 720) return CHIAKI_VIDEO_RESOLUTION_PRESET_720p;
	if(resolution >= 540) return CHIAKI_VIDEO_RESOLUTION_PRESET_540p;
	return CHIAKI_VIDEO_RESOLUTION_PRESET_360p;
}

static void *kz_connect_thread(void *arg)
{
	KZSession *s = arg;
	ChiakiErrorCode err;

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = s->ps5;
	info.host = s->psn ? "" : s->address;
	chiaki_connect_video_profile_preset(&info.video_profile, kz_resolution_preset(s->video.resolution),
		s->video.fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30);
	if(s->video.bitrate_kbps > 0)
		info.video_profile.bitrate = (unsigned int)s->video.bitrate_kbps;
	/* HEVC is PS5-only; PS4 always streams H.264. */
	info.video_profile.codec = (s->video.hevc && s->ps5) ? CHIAKI_CODEC_H265 : CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = false;
	info.enable_dualsense = s->video.enable_dualsense;
	info.audio_video_disabled = CHIAKI_NONE_DISABLED;
	info.auto_regist = false;
	info.rudp_sock = NULL;
	info.packet_loss_max = s->video.packet_loss_max > 0.0 ? s->video.packet_loss_max : 0.05;
	info.enable_idr_on_fec_failure = true;

	ChiakiHolepunchSession hp = NULL;
	if(s->psn)
	{
		err = kz_holepunch_connect(&s->log, s->access_token, s->duid, s->ps5,
			&s->mutex, &s->holepunch, &s->stop_requested, kz_session_stage, s);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			if(err == CHIAKI_ERR_CANCELED)
				kz_emit(s, KZ_EVENT_QUIT, CHIAKI_QUIT_REASON_STOPPED, "Stopped");
			else
			{
				char msg[160];
				snprintf(msg, sizeof(msg), "PSN connection failed: %s", chiaki_error_string(err));
				kz_emit(s, KZ_EVENT_QUIT, KZ_QUIT_CONNECT_FAILED, msg);
			}
			return NULL;
		}
		memcpy(info.psn_account_id, s->account_id, sizeof(info.psn_account_id));
	}
	else
	{
		memcpy(info.regist_key, s->regist_key, sizeof(info.regist_key));
		memcpy(info.morning, s->rp_key, sizeof(info.morning));
	}

	kz_session_stage(s, KZ_STAGE_STREAM);

	pthread_mutex_lock(&s->mutex);
	hp = s->holepunch;
	s->holepunch = NULL; /* chiaki_session_init() takes ownership, even on failure */
	if(s->stop_requested)
	{
		pthread_mutex_unlock(&s->mutex);
		if(hp)
			chiaki_holepunch_session_fini(hp);
		kz_emit(s, KZ_EVENT_QUIT, CHIAKI_QUIT_REASON_STOPPED, "Stopped");
		return NULL;
	}
	info.holepunch_session = hp;
	err = chiaki_session_init(&s->session, &info, &s->log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		pthread_mutex_unlock(&s->mutex);
		char msg[160];
		snprintf(msg, sizeof(msg), "Session init failed: %s", chiaki_error_string(err));
		kz_emit(s, KZ_EVENT_QUIT, KZ_QUIT_CONNECT_FAILED, msg);
		return NULL;
	}
	s->session_inited = true;

	chiaki_session_set_event_cb(&s->session, kz_session_event_cb, s);
	chiaki_session_set_video_sample_cb(&s->session, kz_session_video_cb, s);

	ChiakiAudioSink audio_sink;
	memset(&audio_sink, 0, sizeof(audio_sink));
	chiaki_opus_decoder_get_sink(&s->opus, &audio_sink);
	chiaki_session_set_audio_sink(&s->session, &audio_sink);

	if(s->video.enable_dualsense && s->cb.haptics)
	{
		ChiakiAudioSink haptics_sink;
		memset(&haptics_sink, 0, sizeof(haptics_sink));
		haptics_sink.user = s;
		haptics_sink.frame_cb = kz_haptics_frame_cb;
		chiaki_session_set_haptics_sink(&s->session, &haptics_sink);
	}

	err = chiaki_session_start(&s->session);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		pthread_mutex_unlock(&s->mutex);
		char msg[160];
		snprintf(msg, sizeof(msg), "Session start failed: %s", chiaki_error_string(err));
		kz_emit(s, KZ_EVENT_QUIT, KZ_QUIT_CONNECT_FAILED, msg);
		return NULL;
	}
	s->session_started = true;
	pthread_mutex_unlock(&s->mutex);

	pthread_mutex_lock(&s->input_mutex);
	s->input_live = true;
	pthread_mutex_unlock(&s->input_mutex);
	return NULL;
}

static KZSession *kz_session_alloc(bool ps5, const KZVideoConfig *video, const KZSessionCallbacks *callbacks, int *error_out)
{
	int err = kz_core_init();
	if(err != CHIAKI_ERR_SUCCESS)
	{
		if(error_out) *error_out = err;
		return NULL;
	}
	if(!video || !callbacks || !callbacks->video || !callbacks->event)
	{
		if(error_out) *error_out = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	KZSession *s = calloc(1, sizeof(*s));
	if(!s)
	{
		if(error_out) *error_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	s->ps5 = ps5;
	s->video = *video;
	s->cb = *callbacks;
	pthread_mutex_init(&s->mutex, NULL);
	pthread_mutex_init(&s->input_mutex, NULL);
	kz_log_init(&s->log);
	chiaki_opus_decoder_init(&s->opus, &s->log);
	chiaki_opus_decoder_set_cb(&s->opus, kz_audio_settings_cb, kz_audio_frame_cb, s);
	chiaki_controller_state_set_idle(&s->input_state);
	s->touch_ids[0] = s->touch_ids[1] = -1;
	chiaki_orientation_tracker_init(&s->orient);
	chiaki_accel_new_zero_set_inactive(&s->accel_zero, true);
	atomic_init(&s->connected, false);
	atomic_init(&s->orient_reset, false);
	atomic_init(&s->frames_received, 0);
	atomic_init(&s->frames_lost, 0);
	atomic_init(&s->frames_recovered, 0);
	return s;
}

static void kz_session_free(KZSession *s)
{
	chiaki_opus_decoder_fini(&s->opus);
	pthread_mutex_destroy(&s->mutex);
	pthread_mutex_destroy(&s->input_mutex);
	free(s->address);
	free(s->access_token);
	free(s);
}

KZSession *kz_session_create_lan(const char *address, bool ps5,
	const uint8_t *regist_key, const uint8_t *rp_key,
	const KZVideoConfig *video, const KZSessionCallbacks *callbacks, int *error_out)
{
	if(!address || !*address || !regist_key || !rp_key)
	{
		if(error_out) *error_out = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	KZSession *s = kz_session_alloc(ps5, video, callbacks, error_out);
	if(!s)
		return NULL;
	s->psn = false;
	s->address = kz_strdup(address);
	memcpy(s->regist_key, regist_key, KZ_REGIST_KEY_SIZE);
	memcpy(s->rp_key, rp_key, KZ_RP_KEY_SIZE);
	if(!s->address)
	{
		kz_session_free(s);
		if(error_out) *error_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	if(error_out) *error_out = CHIAKI_ERR_SUCCESS;
	return s;
}

KZSession *kz_session_create_psn(const char *access_token, const char *console_duid_hex,
	bool ps5, const char *psn_account_id_b64,
	const KZVideoConfig *video, const KZSessionCallbacks *callbacks, int *error_out)
{
	if(!access_token || !*access_token)
	{
		if(error_out) *error_out = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	KZSession *s = kz_session_alloc(ps5, video, callbacks, error_out);
	if(!s)
		return NULL;
	s->psn = true;
	if(!kz_parse_hex(console_duid_hex, s->duid, sizeof(s->duid))
		|| !kz_decode_account_id(psn_account_id_b64, s->account_id))
	{
		kz_session_free(s);
		if(error_out) *error_out = CHIAKI_ERR_INVALID_DATA;
		return NULL;
	}
	s->access_token = kz_strdup(access_token);
	if(!s->access_token)
	{
		kz_session_free(s);
		if(error_out) *error_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	if(error_out) *error_out = CHIAKI_ERR_SUCCESS;
	return s;
}

int kz_session_start(KZSession *s)
{
	if(!s)
		return CHIAKI_ERR_INVALID_DATA;
	pthread_mutex_lock(&s->mutex);
	if(s->connect_thread_started)
	{
		pthread_mutex_unlock(&s->mutex);
		return CHIAKI_ERR_INVALID_DATA;
	}
	int r = pthread_create(&s->connect_thread, NULL, kz_connect_thread, s);
	if(r == 0)
		s->connect_thread_started = true;
	pthread_mutex_unlock(&s->mutex);
	return r == 0 ? CHIAKI_ERR_SUCCESS : CHIAKI_ERR_THREAD;
}

void kz_session_stop(KZSession *s)
{
	if(!s)
		return;
	pthread_mutex_lock(&s->mutex);
	s->stop_requested = true;
	if(s->holepunch)
		chiaki_holepunch_main_thread_cancel(s->holepunch, true);
	if(s->session_started)
		chiaki_session_stop(&s->session);
	pthread_mutex_unlock(&s->mutex);
}

void kz_session_destroy(KZSession *s)
{
	if(!s)
		return;
	kz_session_stop(s);
	if(s->connect_thread_started)
		pthread_join(s->connect_thread, NULL);

	pthread_mutex_lock(&s->input_mutex);
	s->input_live = false;
	pthread_mutex_unlock(&s->input_mutex);

	if(s->session_started)
		chiaki_session_join(&s->session);

	pthread_mutex_lock(&s->mutex);
	bool inited = s->session_inited;
	s->session_inited = false;
	s->session_started = false;
	ChiakiHolepunchSession hp = s->holepunch;
	s->holepunch = NULL;
	pthread_mutex_unlock(&s->mutex);

	if(inited)
		chiaki_session_fini(&s->session); /* also finalizes the holepunch session it owns */
	if(hp)
		chiaki_holepunch_session_fini(hp);
	kz_session_free(s);
}

int kz_session_request_idr(KZSession *s)
{
	if(!s)
		return CHIAKI_ERR_INVALID_DATA;
	int r = CHIAKI_ERR_UNINITIALIZED;
	pthread_mutex_lock(&s->mutex);
	if(s->session_started)
		r = (int)chiaki_session_request_idr(&s->session);
	pthread_mutex_unlock(&s->mutex);
	return r;
}

int kz_session_set_login_pin(KZSession *s, const char *pin)
{
	if(!s || !pin)
		return CHIAKI_ERR_INVALID_DATA;
	int r = CHIAKI_ERR_UNINITIALIZED;
	pthread_mutex_lock(&s->mutex);
	if(s->session_inited)
		r = (int)chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
	pthread_mutex_unlock(&s->mutex);
	return r;
}

int kz_session_goto_bed(KZSession *s)
{
	if(!s)
		return CHIAKI_ERR_INVALID_DATA;
	int r = CHIAKI_ERR_UNINITIALIZED;
	pthread_mutex_lock(&s->mutex);
	if(s->session_started)
		r = (int)chiaki_session_goto_bed(&s->session);
	pthread_mutex_unlock(&s->mutex);
	return r;
}

static uint16_t kz_clamp_u16(uint16_t v, uint16_t max_exclusive)
{
	return v >= max_exclusive ? (uint16_t)(max_exclusive - 1) : v;
}

int kz_session_set_input(KZSession *s, const KZControllerInput *in)
{
	if(!s || !in)
		return CHIAKI_ERR_INVALID_DATA;

	pthread_mutex_lock(&s->input_mutex);
	ChiakiControllerState *st = &s->input_state;
	st->buttons = in->buttons;
	st->l2_state = in->l2;
	st->r2_state = in->r2;
	st->left_x = in->left_x;
	st->left_y = in->left_y;
	st->right_x = in->right_x;
	st->right_y = in->right_y;

	/* chiaki identifies fingers by a rolling 7-bit id; keep slot -> id here. */
	for(int i = 0; i < 2; i++)
	{
		uint16_t x = kz_clamp_u16(in->touch_x[i], KZ_TOUCHPAD_WIDTH);
		uint16_t y = kz_clamp_u16(in->touch_y[i], KZ_TOUCHPAD_HEIGHT);
		if(in->touch_active[i])
		{
			if(s->touch_ids[i] < 0)
				s->touch_ids[i] = chiaki_controller_state_start_touch(st, x, y);
			else
				chiaki_controller_state_set_touch_pos(st, (uint8_t)s->touch_ids[i], x, y);
		}
		else if(s->touch_ids[i] >= 0)
		{
			chiaki_controller_state_stop_touch(st, (uint8_t)s->touch_ids[i]);
			s->touch_ids[i] = -1;
		}
	}

	if(atomic_exchange(&s->orient_reset, false))
		chiaki_orientation_tracker_init(&s->orient);

	if(in->motion_valid)
	{
		/* Madgwick orientation from gyro (rad/s) + accel (g), like chiaki's GUI. */
		chiaki_orientation_tracker_update(&s->orient,
			in->gyro_x, in->gyro_y, in->gyro_z,
			in->accel_x, in->accel_y, in->accel_z,
			&s->accel_zero, true, (uint32_t)kz_now_us());
		chiaki_orientation_tracker_apply_to_controller_state(&s->orient, st);
	}

	int r = CHIAKI_ERR_UNINITIALIZED;
	if(s->input_live)
	{
		ChiakiControllerState copy = *st;
		r = (int)chiaki_session_set_controller_state(&s->session, &copy);
	}
	pthread_mutex_unlock(&s->input_mutex);
	return r;
}

void kz_session_get_stats(KZSession *s, KZSessionStats *out)
{
	if(!out)
		return;
	memset(out, 0, sizeof(*out));
	if(!s)
		return;
	out->frames_received = atomic_load(&s->frames_received);
	out->frames_lost = atomic_load(&s->frames_lost);
	out->frames_recovered = atomic_load(&s->frames_recovered);
	out->connected = atomic_load(&s->connected);
	pthread_mutex_lock(&s->mutex);
	if(s->session_inited)
	{
		/* Plain doubles written by chiaki's threads: a torn read is harmless here. */
		out->measured_bitrate_mbps = s->session.stream_connection.measured_bitrate;
		out->packet_loss = s->session.stream_connection.congestion_control.packet_loss;
		out->rtt_ms = (uint32_t)(s->session.rtt_us / 1000);
	}
	pthread_mutex_unlock(&s->mutex);
}

/* ======================================================================== */
/* Audio ring                                                               */
/* ======================================================================== */

struct KZAudioRing
{
	int16_t *buf;                 /* interleaved stereo */
	uint32_t capacity;            /* frames, power of two */
	uint32_t mask;
	uint32_t channels_in;
	uint32_t sample_rate;
	uint32_t target_frames;
	uint32_t max_frames;
	uint32_t fade_frames;

	_Atomic(uint64_t) write_pos;  /* frames, producer-owned */
	_Atomic(uint64_t) read_pos;   /* frames, consumer-owned */
	atomic_bool flush_requested;
	_Atomic(uint64_t) underruns;
	_Atomic(uint64_t) dropped;

	/* producer-only */
	bool producer_fade_in;
	/* consumer-only */
	bool priming;
	uint32_t fade_in_left;
};

KZAudioRing *kz_audio_ring_create(uint32_t channels, uint32_t sample_rate, uint32_t target_ms, uint32_t max_ms)
{
	if(channels < 1 || channels > 2 || sample_rate == 0)
		return NULL;
	KZAudioRing *r = calloc(1, sizeof(*r));
	if(!r)
		return NULL;
	uint32_t want = sample_rate / 4; /* 250 ms of headroom */
	uint32_t cap = 1024;
	while(cap < want)
		cap <<= 1;
	r->buf = calloc((size_t)cap * 2, sizeof(int16_t));
	if(!r->buf)
	{
		free(r);
		return NULL;
	}
	r->capacity = cap;
	r->mask = cap - 1;
	r->channels_in = channels;
	r->sample_rate = sample_rate;
	r->target_frames = sample_rate * target_ms / 1000;
	r->max_frames = sample_rate * max_ms / 1000;
	if(r->max_frames <= r->target_frames)
		r->max_frames = r->target_frames + sample_rate / 100;
	if(r->max_frames > cap)
		r->max_frames = cap;
	r->fade_frames = sample_rate / 200; /* 5 ms */
	if(r->fade_frames == 0)
		r->fade_frames = 1;
	atomic_init(&r->write_pos, 0);
	atomic_init(&r->read_pos, 0);
	atomic_init(&r->flush_requested, false);
	atomic_init(&r->underruns, 0);
	atomic_init(&r->dropped, 0);
	r->producer_fade_in = true;
	r->priming = true;
	return r;
}

void kz_audio_ring_destroy(KZAudioRing *r)
{
	if(!r)
		return;
	free(r->buf);
	free(r);
}

size_t kz_audio_ring_write(KZAudioRing *r, const int16_t *in, size_t frames)
{
	if(!r || !in || frames == 0)
		return 0;
	uint64_t w = atomic_load_explicit(&r->write_pos, memory_order_relaxed);
	uint64_t rd = atomic_load_explicit(&r->read_pos, memory_order_acquire);
	uint64_t fill = w - rd;
	if(fill + frames > r->max_frames)
	{
		/* Backlog above the latency bound (burst after network jitter): shed this
		 * chunk and fade the next one in, instead of letting latency grow. */
		atomic_fetch_add_explicit(&r->dropped, 1, memory_order_relaxed);
		r->producer_fade_in = true;
		return 0;
	}
	for(size_t i = 0; i < frames; i++)
	{
		int16_t lsample, rsample;
		if(r->channels_in == 2)
		{
			lsample = in[2 * i];
			rsample = in[2 * i + 1];
		}
		else
			lsample = rsample = in[i];
		if(r->producer_fade_in && i < r->fade_frames)
		{
			int32_t g = (int32_t)i;
			lsample = (int16_t)(((int32_t)lsample * g) / (int32_t)r->fade_frames);
			rsample = (int16_t)(((int32_t)rsample * g) / (int32_t)r->fade_frames);
		}
		size_t idx = (size_t)((w + i) & r->mask) * 2;
		r->buf[idx] = lsample;
		r->buf[idx + 1] = rsample;
	}
	r->producer_fade_in = false;
	atomic_store_explicit(&r->write_pos, w + frames, memory_order_release);
	return frames;
}

void kz_audio_ring_read(KZAudioRing *r, float *left, float *right, size_t frames)
{
	if(!left)
		return;
	if(!r)
	{
		memset(left, 0, frames * sizeof(float));
		if(right && right != left)
			memset(right, 0, frames * sizeof(float));
		return;
	}

	uint64_t rd = atomic_load_explicit(&r->read_pos, memory_order_relaxed);
	uint64_t w = atomic_load_explicit(&r->write_pos, memory_order_acquire);
	if(atomic_exchange_explicit(&r->flush_requested, false, memory_order_acq_rel))
	{
		rd = w;
		atomic_store_explicit(&r->read_pos, rd, memory_order_release);
		r->priming = true;
	}
	uint64_t fill = w - rd;

	if(r->priming)
	{
		if(fill < r->target_frames)
		{
			memset(left, 0, frames * sizeof(float));
			if(right && right != left)
				memset(right, 0, frames * sizeof(float));
			return;
		}
		r->priming = false;
		r->fade_in_left = r->fade_frames;
	}

	size_t n = fill < frames ? (size_t)fill : frames;
	bool underrun = n < frames;
	const float scale = 1.0f / 32768.0f;
	for(size_t i = 0; i < n; i++)
	{
		size_t idx = (size_t)((rd + i) & r->mask) * 2;
		float l = (float)r->buf[idx] * scale;
		float rr = (float)r->buf[idx + 1] * scale;
		float g = 1.0f;
		if(r->fade_in_left > 0)
		{
			g = (float)(r->fade_frames - r->fade_in_left) / (float)r->fade_frames;
			r->fade_in_left--;
		}
		if(underrun)
		{
			/* About to run dry: fade the tail out instead of clicking. */
			size_t remaining = n - i;
			if(remaining < r->fade_frames)
				g *= (float)remaining / (float)r->fade_frames;
		}
		if(right && right != left)
		{
			left[i] = l * g;
			right[i] = rr * g;
		}
		else
			left[i] = 0.5f * (l + rr) * g;
	}
	for(size_t i = n; i < frames; i++)
	{
		left[i] = 0.0f;
		if(right && right != left)
			right[i] = 0.0f;
	}
	atomic_store_explicit(&r->read_pos, rd + n, memory_order_release);
	if(underrun)
	{
		atomic_fetch_add_explicit(&r->underruns, 1, memory_order_relaxed);
		r->priming = true;
	}
}

void kz_audio_ring_flush(KZAudioRing *r)
{
	if(r)
		atomic_store(&r->flush_requested, true);
}

void kz_audio_ring_get_stats(KZAudioRing *r, KZAudioRingStats *out)
{
	if(!out)
		return;
	memset(out, 0, sizeof(*out));
	if(!r)
		return;
	uint64_t w = atomic_load(&r->write_pos);
	uint64_t rd = atomic_load(&r->read_pos);
	uint64_t fill = w >= rd ? w - rd : 0;
	out->buffered_ms = (uint32_t)(fill * 1000 / r->sample_rate);
	out->underruns = atomic_load(&r->underruns);
	out->dropped_chunks = atomic_load(&r->dropped);
}
