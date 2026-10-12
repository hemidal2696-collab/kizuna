/*
 * Kizuna for iOS/iPadOS - C shim over the chiaki-ng protocol library.
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (C) 2026 Kizuna contributors
 * Portions adapted from TP Play (ios/TPPlay/Platform/Core/TPPlayCore.c,
 * AGPL-3.0, Copyright (C) TP Play contributors) and from Akira
 * (source/core/host.cpp, AGPL-3.0, Copyright (C) Akira contributors).
 *
 * Design rules
 * ------------
 * - This header is the ONLY thing Swift sees (via Bridging-Header.h). It never
 *   exposes a chiaki struct: every chiaki object lives behind an opaque handle.
 *   ChiakiSession's layout depends on build defines (mbedTLS vs OpenSSL, ...),
 *   so the shim is compiled inside the same CMake build as chiaki-lib.
 * - Integer constants are plain #defines so Swift imports them as Int32.
 * - Every callback is invoked on a chiaki (or shim worker) thread, never on the
 *   main thread. Pointers handed to a callback are only valid during the call.
 * - Error codes are chiaki's ChiakiErrorCode values (0 == success).
 */

#ifndef KIZUNA_CORE_H
#define KIZUNA_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------ */
/* Constants                                                                */
/* ------------------------------------------------------------------------ */

#define KZ_OK                    0
#define KZ_ERR_UNKNOWN           1
#define KZ_ERR_MEMORY            4
#define KZ_ERR_NETWORK           6
#define KZ_ERR_INVALID_DATA      11
#define KZ_ERR_CANCELED          14
#define KZ_ERR_TIMEOUT           15

#define KZ_REGIST_KEY_SIZE       16   /* CHIAKI_SESSION_AUTH_SIZE */
#define KZ_RP_KEY_SIZE           16   /* "morning" */
#define KZ_SERVER_MAC_SIZE       6
#define KZ_DUID_SIZE             32   /* PSN device uid, bytes (64 hex chars) */
#define KZ_PSN_ACCOUNT_ID_SIZE   8
#define KZ_TRIGGER_EFFECT_SIZE   10

/* Log levels (same bits as ChiakiLogLevel). */
#define KZ_LOG_ERROR             0x01
#define KZ_LOG_WARNING           0x02
#define KZ_LOG_INFO              0x04
#define KZ_LOG_VERBOSE           0x08
#define KZ_LOG_DEBUG             0x10

/* Host state reported by discovery. */
#define KZ_HOST_STATE_UNKNOWN    0
#define KZ_HOST_STATE_READY      1
#define KZ_HOST_STATE_STANDBY    2

/* ChiakiTarget values (must not change, they are chiaki's). */
#define KZ_TARGET_PS4_UNKNOWN    0
#define KZ_TARGET_PS4_8          800
#define KZ_TARGET_PS4_9          900
#define KZ_TARGET_PS4_10         1000
#define KZ_TARGET_PS5_UNKNOWN    1000000
#define KZ_TARGET_PS5_1          1000100

/* Controller buttons (same bits as ChiakiControllerButton). */
#define KZ_BTN_CROSS             0x0001
#define KZ_BTN_MOON              0x0002   /* circle   */
#define KZ_BTN_BOX               0x0004   /* square   */
#define KZ_BTN_PYRAMID           0x0008   /* triangle */
#define KZ_BTN_DPAD_LEFT         0x0010
#define KZ_BTN_DPAD_RIGHT        0x0020
#define KZ_BTN_DPAD_UP           0x0040
#define KZ_BTN_DPAD_DOWN         0x0080
#define KZ_BTN_L1                0x0100
#define KZ_BTN_R1                0x0200
#define KZ_BTN_L3                0x0400
#define KZ_BTN_R3                0x0800
#define KZ_BTN_OPTIONS           0x1000
#define KZ_BTN_SHARE             0x2000   /* "Create" on DualSense */
#define KZ_BTN_TOUCHPAD          0x4000
#define KZ_BTN_PS                0x8000

/* Touchpad coordinate space used by Kizuna (PS5 DualSense). */
#define KZ_TOUCHPAD_WIDTH        1920
#define KZ_TOUCHPAD_HEIGHT       1080

/* Registration outcome. */
#define KZ_REGIST_SUCCESS        0
#define KZ_REGIST_FAILED         1
#define KZ_REGIST_CANCELED       2

/* Progress stages of the PSN (holepunch) path, used for registration and
 * for remote streaming. */
#define KZ_STAGE_PSN_SESSION     1   /* creating the session on PSN servers */
#define KZ_STAGE_PSN_CONSOLE     2   /* asking the console to join         */
#define KZ_STAGE_PSN_PUNCH       3   /* NAT hole punching (control socket)  */
#define KZ_STAGE_REGIST          4   /* registration exchange               */
#define KZ_STAGE_STREAM          5   /* session/stream start                */
#define KZ_STAGE_PSN_WAKE        6   /* console did not answer yet (waking from rest), retrying */

/* Session events delivered through KZEventCallback. */
#define KZ_EVENT_CONNECTED           1
#define KZ_EVENT_QUIT                2   /* code = quit reason, message = text   */
#define KZ_EVENT_LOGIN_PIN_REQUEST   3   /* code = 1 if previous PIN was wrong   */
#define KZ_EVENT_PROGRESS            4   /* code = KZ_STAGE_*                    */
#define KZ_EVENT_NICKNAME            5   /* message = console nickname          */
#define KZ_EVENT_MOTION_RESET        6
#define KZ_EVENT_LED_COLOR           7   /* code = 0xRRGGBB                      */
#define KZ_EVENT_PLAYER_INDEX        8   /* code = player index                  */
#define KZ_EVENT_HAPTIC_INTENSITY    9   /* code = 0 off, 1 strong .. 3 weak     */
#define KZ_EVENT_TRIGGER_INTENSITY   10  /* code = 0 off, 1 strong .. 3 weak     */
#define KZ_EVENT_DATA_HOLEPUNCH      11  /* code = 1 when finished               */

/* Quit "reason" used when the shim itself fails before chiaki reports one. */
#define KZ_QUIT_CONNECT_FAILED       1000

/* ------------------------------------------------------------------------ */
/* Library                                                                  */
/* ------------------------------------------------------------------------ */

typedef void (*KZLogCallback)(int level, const char *message, void *user);

/** Idempotent chiaki_lib_init(). Returns KZ_OK or a chiaki error code. */
int kz_core_init(void);
/** Global log sink for every chiaki object created by the shim. */
void kz_core_set_log_callback(KZLogCallback callback, void *user);
/** Bit mask of KZ_LOG_* levels to forward (default: ERROR|WARNING|INFO). */
void kz_core_set_log_mask(uint32_t mask);
const char *kz_core_version(void);
const char *kz_error_string(int code);
const char *kz_quit_reason_string(int reason);
bool kz_quit_reason_is_error(int reason);

/** Generates a client DUID ("0000000700410080" + 32 hex). out_size >= 49. */
int kz_generate_client_duid(char *out, size_t out_size);

/* ------------------------------------------------------------------------ */
/* Discovery                                                                */
/* ------------------------------------------------------------------------ */

/** All strings are NUL-terminated, never NULL, valid only during the callback. */
typedef struct KZDiscoveredHost {
	int state;                     /* KZ_HOST_STATE_* */
	bool is_ps5;
	int target;                    /* KZ_TARGET_* */
	uint16_t request_port;
	const char *address;
	const char *name;
	const char *host_id;           /* MAC address as 12 hex chars */
	const char *host_type;         /* "PS5" / "PS4" */
	const char *system_version;
	const char *running_app_name;
	const char *running_app_titleid;
} KZDiscoveredHost;

typedef void (*KZDiscoveryCallback)(const KZDiscoveredHost *host, void *user);

typedef struct KZDiscovery KZDiscovery;

/**
 * Opens a UDP socket (local port 9303..9319) and a receive thread.
 * Without the multicast entitlement iOS forbids broadcast, so Kizuna probes
 * by unicast: kz_discovery_sweep() sends a SRCH to every host of each local
 * IPv4 /24 (both the PS5 port 9302 and the PS4 port 987).
 */
KZDiscovery *kz_discovery_create(KZDiscoveryCallback callback, void *user, int *error_out);
/** Unicast sweep of every local /24 (skips loopback, cellular and VPN). Returns number of probes sent. */
int kz_discovery_sweep(KZDiscovery *discovery);
/** Unicast SRCH to a single address (both ports). */
int kz_discovery_probe(KZDiscovery *discovery, const char *address);
/** Stops the receive thread and closes the socket. */
void kz_discovery_destroy(KZDiscovery *discovery);

/** Sends a WAKEUP packet. regist_key: the 16 raw bytes returned by registration. */
int kz_wakeup(const char *address, const uint8_t *regist_key, bool ps5);

/* ------------------------------------------------------------------------ */
/* PSN device list (chiaki_holepunch_list_devices)                          */
/* ------------------------------------------------------------------------ */

typedef struct KZPSNDevice {
	const char *name;
	const char *duid_hex;            /* 64 lower-case hex chars */
	bool is_ps5;
	bool remoteplay_enabled;
} KZPSNDevice;

typedef void (*KZPSNDeviceCallback)(const KZPSNDevice *device, void *user);

/** Blocking HTTP call (run it off the main thread). Calls `callback` once per
 *  console of the given type linked to the account. Returns a chiaki error code. */
int kz_psn_list_devices(const char *access_token, bool ps5, KZPSNDeviceCallback callback, void *user);

/* ------------------------------------------------------------------------ */
/* Registration                                                             */
/* ------------------------------------------------------------------------ */

typedef struct KZRegistResult {
	int target;
	const uint8_t *regist_key;      /* KZ_REGIST_KEY_SIZE bytes (ASCII hex, NUL padded) */
	const uint8_t *rp_key;          /* KZ_RP_KEY_SIZE bytes */
	uint32_t rp_key_type;
	const uint8_t *server_mac;      /* KZ_SERVER_MAC_SIZE bytes */
	const char *server_nickname;
	const char *console_address;    /* PSN path: address selected by holepunch, may be "" */
	uint32_t console_pin;
} KZRegistResult;

/** Called exactly once from a worker thread. result is NULL unless status == KZ_REGIST_SUCCESS. */
typedef void (*KZRegistCallback)(int status, const KZRegistResult *result, const char *error_message, void *user);
typedef void (*KZProgressCallback)(int stage, void *user);

typedef struct KZRegistration KZRegistration;

/**
 * Classic LAN registration with the 8-digit PIN shown on the console
 * (Settings > System > Remote Play > Link Device).
 * psn_account_id_b64: base64 of the 8-byte account id (PS4 >= 7.0 and PS5).
 */
KZRegistration *kz_regist_start_pin(const char *address, int target,
	const char *psn_account_id_b64, uint32_t pin,
	KZRegistCallback callback, void *user, int *error_out);

/**
 * PIN-less registration through PSN, like the official app (ported from
 * Akira's Host::registerHostAuto / connectHolepunch): holepunch session
 * create -> offer -> start for the console DUID -> punch the CTRL hole ->
 * RUDP over that socket -> chiaki_regist_start with holepunch info and pin 0.
 * access_token must come from the Remote Play OAuth client authorized with
 * the same client DUID. console_duid_hex: 64 hex chars from the PSN device list.
 */
KZRegistration *kz_regist_start_psn(const char *access_token, const char *console_duid_hex,
	bool ps5, const char *psn_account_id_b64,
	KZProgressCallback progress, KZRegistCallback callback, void *user, int *error_out);

/** Requests cancellation; the callback still fires (with KZ_REGIST_CANCELED). */
void kz_regist_cancel(KZRegistration *registration);
/** Joins the worker and frees. Safe to call from any thread except a
 *  callback of the same registration (then it detaches instead). */
void kz_regist_destroy(KZRegistration *registration);

/* ------------------------------------------------------------------------ */
/* Streaming session                                                        */
/* ------------------------------------------------------------------------ */

/** Annex-B access unit. Return false when the frame could not be consumed:
 *  chiaki then reports a corrupt frame and the console sends a new IDR. */
typedef bool (*KZVideoCallback)(const uint8_t *data, size_t size, int32_t frames_lost, bool frame_recovered, void *user);
typedef void (*KZAudioSettingsCallback)(uint32_t channels, uint32_t sample_rate, void *user);
/** Interleaved int16 PCM after chiaki's Opus decoder; frames = samples per channel. */
typedef void (*KZAudioFrameCallback)(const int16_t *pcm, size_t frames, uint32_t channels, void *user);
/** DualSense haptics PCM: interleaved stereo int16 at 3 kHz (left, right). */
typedef void (*KZHapticsCallback)(const int16_t *pcm, size_t frames, void *user);
typedef void (*KZRumbleCallback)(uint8_t left, uint8_t right, void *user);
/** Raw DualSense trigger effect descriptors (mode byte + 10 parameter bytes). */
typedef void (*KZTriggerCallback)(uint8_t type_left, const uint8_t *left, uint8_t type_right, const uint8_t *right, void *user);
typedef void (*KZEventCallback)(int type, int code, const char *message, void *user);

typedef struct KZSessionCallbacks {
	KZVideoCallback video;
	KZAudioSettingsCallback audio_settings;
	KZAudioFrameCallback audio_frame;
	KZHapticsCallback haptics;          /* may be NULL */
	KZRumbleCallback rumble;            /* may be NULL */
	KZTriggerCallback triggers;         /* may be NULL */
	KZEventCallback event;
	void *user;
} KZSessionCallbacks;

typedef struct KZVideoConfig {
	int resolution;          /* 360, 540, 720 or 1080 */
	int fps;                 /* 30 or 60 */
	int bitrate_kbps;        /* 0 = chiaki preset default */
	bool hevc;               /* H.265 (PS5 only) or H.264 */
	bool enable_dualsense;   /* haptics + adaptive triggers + DualSense touchpad */
	double packet_loss_max;  /* 0 = default 0.05 */
} KZVideoConfig;

typedef struct KZSession KZSession;

/** LAN session with stored registration keys. Nothing touches the network
 *  until kz_session_start(). */
KZSession *kz_session_create_lan(const char *address, bool ps5,
	const uint8_t *regist_key, const uint8_t *rp_key,
	const KZVideoConfig *video, const KZSessionCallbacks *callbacks, int *error_out);

/** Away-from-home session through PSN holepunch. The holepunch handshake
 *  runs on the shim's connect thread after kz_session_start(). */
KZSession *kz_session_create_psn(const char *access_token, const char *console_duid_hex,
	bool ps5, const char *psn_account_id_b64,
	const KZVideoConfig *video, const KZSessionCallbacks *callbacks, int *error_out);

/** Starts the connect thread. Failures arrive as KZ_EVENT_QUIT. */
int kz_session_start(KZSession *session);
/** Asynchronous stop request (cancels holepunch / stops chiaki). */
void kz_session_stop(KZSession *session);
/** Stops, joins every thread and frees. Blocking: never call it on the main
 *  thread or from a session callback. */
void kz_session_destroy(KZSession *session);

int kz_session_request_idr(KZSession *session);
int kz_session_set_login_pin(KZSession *session, const char *pin);
int kz_session_goto_bed(KZSession *session);

typedef struct KZControllerInput {
	uint32_t buttons;                 /* KZ_BTN_* */
	uint8_t l2;
	uint8_t r2;
	int16_t left_x, left_y;           /* -32768..32767, +y = down */
	int16_t right_x, right_y;
	bool touch_active[2];
	uint16_t touch_x[2];              /* 0..KZ_TOUCHPAD_WIDTH-1  */
	uint16_t touch_y[2];              /* 0..KZ_TOUCHPAD_HEIGHT-1 */
	bool motion_valid;
	float gyro_x, gyro_y, gyro_z;     /* rad/s */
	float accel_x, accel_y, accel_z;  /* g */
} KZControllerInput;

/** Thread-safe. Touch ids and the orientation quaternion are tracked here. */
int kz_session_set_input(KZSession *session, const KZControllerInput *input);

typedef struct KZSessionStats {
	double measured_bitrate_mbps;
	double packet_loss;               /* 0..1, congestion control estimate */
	uint64_t frames_received;
	uint64_t frames_lost;
	uint64_t frames_recovered;
	uint32_t rtt_ms;
	bool connected;
} KZSessionStats;

void kz_session_get_stats(KZSession *session, KZSessionStats *out);

/* ------------------------------------------------------------------------ */
/* Lock-free SPSC audio ring (int16 in, float out) with bounded latency.    */
/* Lives in C because Swift has no portable atomics on iOS 17.              */
/* ------------------------------------------------------------------------ */

typedef struct KZAudioRing KZAudioRing;

typedef struct KZAudioRingStats {
	uint32_t buffered_ms;
	uint64_t underruns;
	uint64_t dropped_chunks;
} KZAudioRingStats;

/**
 * channels: 1 or 2 (input layout); output is always stereo float.
 * target_ms: amount buffered before playback (re)starts (e.g. 30).
 * max_ms: writes that would exceed this are shed with a fade (e.g. 60).
 */
KZAudioRing *kz_audio_ring_create(uint32_t channels, uint32_t sample_rate, uint32_t target_ms, uint32_t max_ms);
void kz_audio_ring_destroy(KZAudioRing *ring);
/** Producer side (one thread). Returns frames accepted. */
size_t kz_audio_ring_write(KZAudioRing *ring, const int16_t *interleaved, size_t frames);
/** Consumer side (the audio render thread). Always fills `frames` samples
 *  (silence on underrun). right may equal left for mono output. */
void kz_audio_ring_read(KZAudioRing *ring, float *left, float *right, size_t frames);
/** Consumer side: drop everything buffered and wait for target_ms again. */
void kz_audio_ring_flush(KZAudioRing *ring);
void kz_audio_ring_get_stats(KZAudioRing *ring, KZAudioRingStats *out);

#ifdef __cplusplus
}
#endif

#endif /* KIZUNA_CORE_H */
