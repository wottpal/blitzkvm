// Limits, in bytes and seconds.

export const MAX_MESSAGE = 64 * 1024; // a WebSocket message or a POST body
// The broker's messages carry a request's screen (a JPEG of up to 64 KiB,
// base64 twice by the time it's a box in a send).
export const MAX_BROKER_MESSAGE = 192 * 1024;
export const MAX_ENROLL = 8 * 1024; // an enroll POST body
export const MIN_BOX = 65 + 16; // HPKE enc and the AEAD tag

export const QUEUE_TTL = 120;
export const MAX_QUEUED = 64; // boxes per recipient and sender
export const MAX_QUEUED_BYTES = 1024 * 1024; // per recipient
export const MAX_OBJECT_BYTES = 8 * 1024 * 1024; // everything queued for one broker
export const NONCE_MARGIN = 60; // a nonce is kept until issued + MAX_SKEW + this
export const AUTH_TIMEOUT = 10; // to answer a hello: one round trip

export const MAX_APPROVERS = 64; // the broker's rosters have at most as many
export const MAX_DEVICES = 4; // APNs tokens per approver, newest kept
export const MAX_PENDING_SOCKETS = 16; // not authenticated yet
// Authenticated sockets are one per party (the broker and Macs on the allow
// list); this backs that up.
export const MAX_SOCKETS = 1 + MAX_APPROVERS + MAX_PENDING_SOCKETS;

export const HOUR = 3600;
export const DAY = 24 * HOUR;
// A request takes up to 7 pushes per iPhone: the first, 5 repeats until it's
// answered, and the quiet one that ends it.
export const PUSHES_PER_HOUR = 360; // per broker
// Repeats stop at this many of the hour's pushes: the rest is for first
// pushes and the quiet ones that end requests.
export const REPEATS_PER_HOUR = 300;
export const PUSHES_PER_DAY = 2000; // per device token
// Pushes that alert (sound, through Focus) per device token; past these a
// push still arrives, quietly. A request alerts at most 6 times in 2 minutes.
export const ALERTS_PER_HOUR = 120;
export const ALERTS_PER_MINUTE = 12;
// Enrollments go to a pairing the broker announced, a few per pairing.
export const MAX_PAIRINGS = 16;
export const ENROLLS_PER_PAIRING = 3;
export const PAIRING_LIFETIME = 5 * 60;
export const ENROLLS_PER_HOUR = 30; // per broker
export const ENROLLS_PER_HOUR_PER_CLIENT = 5; // per IP address (IPv6: per /64)
export const BOXES_TO_BROKER_PER_MINUTE = 60; // per approver
// A socket that hasn't pinged for this long is taken for gone (the broker
// pings every 30 s, Macs every 20 s).
export const DEAD_SOCKET = 75;
export const IDLE_LIFETIME = 90 * DAY; // a broker gone this long is forgotten
export const APNS_TIMEOUT = 10;

export const MAX_PUSH_PAYLOAD = 3500;
export const MAX_COLLAPSE_ID = 64;
