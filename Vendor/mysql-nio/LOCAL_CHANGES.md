Based on vapor/mysql-nio 1.8.0, commit 853b43413941a7fc0cfe44ef0ae81b6dd049f8e5 (MIT).

LuckySQL carries a small transport patch because 1.8.0 silently falls back to
plaintext when a server does not advertise CLIENT_SSL, even with TLS configured.
The patch rejects that handshake before sending authentication, adds async host
resolution through NIO, connect/handshake deadlines and channel cancellation,
and completes the handshake future when a half-open connection closes.
Upstream source and license are preserved; upstream tests are not vendored.

- Expose an optional additional peer-certificate verification callback. LuckySQL
  uses it for strict macOS hostname policy after NIOSSL verifies the certificate
  chain. NIOSSL's normal IP SAN fallback must not override an explicitly requested
  DNS identity. This uses NIOSSL's underscored additional-verification API, pinned
  to 2.34.1 and covered by the live TLS fixture matrix.

- Adjust the informational version check to the tested MySQL 5.6 baseline;
  LuckySQL explicitly negotiates utf8mb4_general_ci before user SQL.

- Bound asynchronous DNS plus TCP resolution with an event-loop deadline; close
  channels that arrive after timeout so delayed resolution cannot leak a socket.
