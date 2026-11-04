# Androp protocol v3 — streamed originals

Local RFC 6455 WebSocket, Bonjour `_androp._tcp.`, default TCP 8989. JSON **text** controls; raw **binary** file chunks. Devices use trusted Wi-Fi: the pairing code and traffic are not encrypted. Pairing is an access gate, not hostile-network security.

## Pairing and ownership

```json
{"type":"HELLO","code":"123456","version":3}
{"type":"AUTH","ok":true,"version":3,"chunkBytes":262144}
```

The Mac permits four connected sockets, closes unauthenticated peers after 10 seconds, and rate-limits failed authentication to five attempts/minute across peers. New Android clients require AUTH version >= 3. An open socket alone does not mean paired.

One pending gesture or upload belongs to one authenticated socket. A second peer cannot update, cancel, append to, or finish it. Another ENTER receives RESULT false while the receiver is busy. An owner's repeated ENTER with the same ID enriches edge-preview metadata at drop time.

## Follow a gesture from any edge

```json
{"type":"DRAG_ENTER","id":"unique-id","name":"Photo.heic","mimeType":"image/heic","thumbnail":"small-preview-base64-or-empty","edge":"RIGHT"}
{"type":"DRAG_UPDATE","id":"unique-id","normalizedY":0.46,"crossRatio":0.65,"velocityX":-700,"velocityY":0}
```

- Transfer IDs: nonempty, <=80 characters. Names: <=255 characters. Receiver sanitizes names to a safe, collision-free inbox leaf.
- Thumbnail: required string, empty for non-images. Maximum 512 KiB encoded/384 KiB decoded. `data:` prefixes supported. Android samples previews <=480px; Mac decodes them to <=512px off main.
- Edge means **receiving Mac edge**. Phone LEFT → Mac RIGHT; RIGHT → LEFT; TOP → BOTTOM; BOTTOM → TOP. All four Android edges participate automatically. This derives direction from the gesture; it does not locate physical devices with Wi-Fi.
- `normalizedY`: top-to-bottom on vertical edges, left-to-right on horizontal edges (legacy field name). `crossRatio`: [0,1], the share of the card already past the phone's edge; the Mac shows exactly that share. Velocity is pixels/second, clamped for animation.
- Idle Android seams are 6 physical pixels. A global system drag expands all four drop zones to 64dp and lights their guide. This catches a drop before its pointer has to hit the exact bezel pixel. Ordinary local/in-app drags from another app cannot be captured.

## Stream instead of a whole base64 file

```json
{"type":"DRAG_RELEASE","id":"unique-id","action":"COMMIT","velocityX":0,"velocityY":0,"stream":true,"size":67108864}
{"type":"TRANSFER_READY","id":"unique-id"}
```

`size` is an optional nonnegative Int64; omit for providers with unknown lengths. There is **no fixed file-size cap** on v3. The receiver checks available disk capacity, leaving a 64 MiB free-space reserve. OS/provider/file-system limits still apply.

After READY, send a raw binary chunk of at most **256 KiB**. The receiver writes it to its hidden temporary file and replies:

```json
{"type":"CHUNK_ACK","id":"unique-id","received":262144}
```

`received` is the cumulative byte count written to the temporary file; final RESULT follows verification and synchronization. Current senders use a sliding window of at most **eight chunks / 2 MiB** in flight. Track each chunk's ending byte offset, consume matching ACKs in order, and free one slot per ACK. Final END is sent only after every outstanding chunk is acknowledged. The receiver still writes sequentially, so older one-chunk senders remain compatible. This bounds application buffers without paying a full Wi-Fi round trip between every chunk or filling OkHttp's outgoing queue. Both native apps hash incrementally. Throttled UI progress is independent of chunk acknowledgements. There is no total-duration timeout; 60 seconds without progress expires an upload. The sender also waits at most 60 seconds per READY/chunk/final response.

After EOF:

```json
{"type":"TRANSFER_END","id":"unique-id","bytes":67108864,"sha256":"64-lowercase-hex-characters"}
```

The receiver verifies total bytes, declared size when present, and SHA-256; synchronizes/closes the file; moves it into the inbox without replacing anything; and applies quarantine metadata. Then:

```json
{"type":"RESULT","id":"unique-id","ok":true,"name":"Photo (1).heic","error":""}
```

Errors return RESULT false with an explanation. Never display success on socket enqueue or CHUNK_ACK alone. Hash failures, length mismatches, disk failures, cancellation and disconnect remove temporary files. Empty files use READY → END with the empty SHA-256. A lost final ACK can mean the file was saved: check the inbox before retrying. Durable resume/replay deduplication is not implemented.

## Cancel and compatibility

RELEASE with `action: CANCEL` and no data cancels a pending gesture or active stream. It publishes no file. An idle pending gesture expires after 30 seconds; a live stream uses the separate inactivity deadline. WebSocket ping/pong is supported; legacy JSON PING is a no-op.

For existing v2 clients only, RELEASE may still carry `fullData` base64. That **legacy message path** remains capped at 8 MiB decoded and 12 MiB/frame; it is not used by current native apps, Python simulator or browser lab. v1 clients lacking HELLO remain unsupported.

Default inbox: `~/Downloads/Androp`. `ANDROP_INBOX` selects an isolated test directory. `-listenPort 18989` selects a separate test listener without affecting the production port. Media auto-open is opt-in. Menu preview saves no file.
