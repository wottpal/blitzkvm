// Limits, in bytes and seconds.

export const MAX_MESSAGE = 64 * 1024; // a WebSocket message or a POST body
export const MAX_ENROLL = 8 * 1024; // an enroll POST body
export const MIN_BOX = 65 + 16; // HPKE enc and the AEAD tag

export const QUEUE_TTL = 120;
export const MAX_QUEUED = 64; // boxes per recipient and sender
export const MAX_QUEUED_BYTES = 1024 * 1024; // per recipient
export const MAX_OBJECT_BYTES = 8 * 1024 * 1024; // everything queued for one broker
export const NONCE_MARGIN = 60; // a nonce is kept until issued + MAX_SKEW + this
export const AUTH_TIMEOUT = 30; // to answer a hello

export const MAX_APPROVERS = 64; // the broker's rosters have at most as many
export const MAX_DEVICES = 4; // APNs tokens per approver, newest kept
export const MAX_PENDING_SOCKETS = 16; // not authenticated yet
// Authenticated sockets are one per party (the broker and Macs on the allow
// list); this backs that up.
export const MAX_SOCKETS = 1 + MAX_APPROVERS + MAX_PENDING_SOCKETS;

export const HOUR = 3600;
export const DAY = 24 * HOUR;
export const PUSHES_PER_HOUR = 60; // per broker
export const PUSHES_PER_DAY = 500; // per device token
export const ENROLLS_PER_HOUR = 10; // per broker
export const ENROLLS_PER_HOUR_PER_CLIENT = 5; // per IP address (IPv6: per /64)

export const MAX_PUSH_PAYLOAD = 3500;
export const MAX_COLLAPSE_ID = 64;
