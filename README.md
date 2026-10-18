# Native macOS 12 (Monterey) iMessage & SMS Relay Daemon (`crapple-relay-12`) `v0.2.0`

A high-performance, bidirectional native daemon designed specifically for macOS 12.7.x (Monterey). It links directly against Apple's private `IMCore`, `IMFoundation`, and `IMSharedUtilities` frameworks to provide a headless HTTP REST API and real-time webhook bridge for iMessage and SMS.

This daemon acts as an agnostic middleware layer: it can connect to **any** gateway, bot, or bridge (such as a Signal bridge, Matrix puppeting bridge, Telegram/Discord bot, automated alerting system, or custom CRM).

---

## Table of Contents
1. [Capabilities: What This Can and Cannot Do](#1-capabilities-what-this-can-and-cannot-do)
2. [System Protections & Security Implications](#2-system-protections--security-implications)
3. [Build Requirements & Procedures](#3-build-requirements--procedures)
4. [Gateway Route Contract & API Reference](#4-gateway-route-contract--api-reference)
   - [Inbound Webhook (Relay → Gateway)](#inbound-webhook-relay--gateway)
   - [Outbound Send (Gateway → Relay)](#outbound-send-gateway--relay)
   - [Outbound Tapback Reactions (Gateway → Relay)](#outbound-tapback-reactions-gateway--relay)
   - [Diagnostics & Management Endpoints](#diagnostics--management-endpoints)
5. [Networking Requirements & Topologies](#5-networking-requirements--topologies)
6. [Daemon Deployment with launchd](#6-daemon-deployment-with-launchd)

---

## 1. Capabilities: What This Can and Cannot Do

### What It CAN Do
- **Headless Native Bridge:** Runs 24/7 as a background daemon (`launchd`). The macOS `Messages.app` GUI does **not** need to be open or running.
- **Direct Framework Integration:** Links directly against macOS private frameworks (`IMCore.framework`, `IMFoundation.framework`, `IMSharedUtilities.framework`) and communicates with `imagent` over Mach XPC.
- **Outbound Message Sending (`POST /send`):**
  - Plain text messages.
  - Multi-line messages with Unicode/emojis.
  - Media attachments (photos, videos, audio clips, PDFs, arbitrary documents) via base64 payloads.
  - Combined text + attachment messages (pictures with captions).
- **Outbound Tapback Reactions (`POST /react`):**
  - Sends all standard iMessage Tapbacks: **Love**, **Like**, **Dislike**, **Laugh**, **Emphasize**, and **Question**.
  - Supports removal of existing Tapbacks.
  - Automatic recipient and chat resolution from message GUIDs via SQLite `chat.db` queries.
  - Generates backward-compatibility fallback strings for non-iMessage recipients (e.g. `Loved “...”`).
- **Real-Time Inbound Webhooks (`POST /receive-imessage`):**
  - Pushes incoming messages and media to your gateway listener in real-time.
  - Dual observation architecture: combines `IMChat` notification center events with a high-frequency SQLite WAL observer on `~/Library/Messages/chat.db` for 100% capture reliability.
  - Automatic base64 encoding and MIME detection of incoming media attachments.
- **Security & Logging:**
  - Enforces Bearer token authentication on all inbound REST endpoints.
  - Native system logging via Apple Unified Logging (`os_log`) and POSIX `syslog(3)` without creating disk log clutter.

### What It CANNOT Do
- **Cannot Run on Linux or Windows:** Apple's iMessage protocol relies on proprietary Apple Push Notification service (APNs), hardware-backed keys, and the Identity Services (`identityservicesd`) daemon. It **must** execute on a physical Mac or macOS VM running macOS 12 Monterey.
- **Cannot Run in a Pre-Login / Locked FileVault State:** The daemon requires an unlocked user session because macOS encrypts the user Keychain and `~/Library/Messages/chat.db` at rest until the user logs into macOS.
- **Cannot Bypass Apple ID / Carrier Requirements:** 
  - To send/receive iMessages, an active Apple ID must be logged into iMessage on the Mac.
  - To send/receive green-bubble SMS messages, an iPhone on the same Apple ID must have **Text Message Forwarding** enabled for this Mac.
- **Cannot Edit or Unsend Messages:** Message editing and unsending are features introduced in iOS 16 / macOS 13 (Ventura). macOS 12 (Monterey) does not support message modification.

---

## 2. System Protections & Security Implications

To interact with private Apple messaging frameworks and access the SQLite message database, macOS system protections must be configured accordingly.

### 1. System Integrity Protection (SIP) & Apple Mobile File Integrity (AMFI)
Apple restricts private entitlements (such as `com.apple.private.imcore.imstatusagent`) to first-party binaries signed by Apple. An ad-hoc or self-signed binary attempting to claim these entitlements will be terminated by the kernel (`AMFI`) unless protections are adjusted.

- **Requirement:** 
  - SIP must be disabled (`csrutil disable` in Recovery Mode), OR
  - AMFI must be instructed to permit ad-hoc private entitlements (e.g. boot argument `amfi_get_out_of_my_way=1`).
- **Security Implications:**
  - Disabling SIP permits processes with root or user privileges to modify protected system files and load unsigned kernel extensions.
  - Relaxing AMFI allows any local binary to claim privileged private entitlements.
  - **Mitigation:** Run the daemon on a dedicated Mac or isolated virtual machine. Do not expose the HTTP port to the public internet; bind strictly to `localhost` or an encrypted private overlay network (Tailscale/WireGuard), and use a strong Bearer token.

### 2. Transparency, Consent, and Control (TCC / Full Disk Access)
macOS sandbox rules protect user message history stored at `~/Library/Messages/chat.db`.

- **Requirement:** 
  - The compiled binary (`imessage-relay`) or the parent execution context (e.g., Terminal or launchd wrapper) must be granted **Full Disk Access** under:
    `System Preferences` → `Security & Privacy` → `Privacy` → `Full Disk Access`.
- **Security Implications:**
  - Any binary with Full Disk Access can read all user databases (Mail, Safari history, Messages, Calendar).

---

## 3. Build Requirements & Procedures

### Prerequisites
- macOS 12.7.x (Monterey) on Intel (`x86_64`) or Apple Silicon (`arm64`).
- Xcode Command Line Tools installed:
  ```bash
  xcode-select --install
  ```

### Entitlements File (`entitlements.plist`)
The binary requires private entitlements to connect to `imagent`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.private.imcore.imstatusagent</key>
    <true/>
    <key>com.apple.private.tcc.allow</key>
    <array>
        <string>kTCCServiceAddressBook</string>
    </array>
</dict>
</plist>
```

### Build Script (`build.sh`)
Compile and sign the binary using the provided build script:
```bash
./build.sh
```

Under the hood, this executes:
```bash
# 1. Compile Objective-C source linking private frameworks directly
clang -fobjc-arc \
      -fno-modules \
      -O2 \
      -Wall \
      -Wno-deprecated-declarations \
      -F/System/Library/PrivateFrameworks \
      -framework Foundation \
      -framework IMCore \
      -framework IMFoundation \
      -framework IMSharedUtilities \
      -lsqlite3 \
      -I. \
      main.m \
      -o imessage-relay

# 2. Ad-hoc codesign with private entitlements
codesign -s - --force --entitlements entitlements.plist imessage-relay
```

---

## 4. Gateway Route Contract & API Reference

All requests between the gateway and the relay daemon use **JSON** and are authenticated via HTTP Bearer token.

### Authentication Header
```http
Authorization: Bearer <YOUR_AUTH_TOKEN>
Content-Type: application/json
```

---

### Inbound Webhook (Relay → Gateway)
When an external contact sends an iMessage or SMS to the Mac, the relay daemon immediately dispatches an HTTP POST request to the configured gateway webhook URL.

- **Method:** `POST`
- **Default URL:** `http://<GATEWAY_HOST>:<PORT>/receive-imessage`
- **Payload Schema:**

  **1-on-1 Message:**
  ```json
  {
    "sender": "+15551234567",
    "from": "+15551234567",
    "participant": "+15551234567",
    "is_group": false,
    "chat_identifier": "+15551234567",
    "chat_guid": "iMessage;-;+15551234567",
    "group_name": "",
    "message": "Hello from external contact!",
    "attachment_base64": "",
    "attachment_mime": "",
    "attachment_name": ""
  }
  ```

  **Group Chat Message:**
  ```json
  {
    "sender": "chat123456789012345678",
    "from": "alice@example.com",
    "participant": "alice@example.com",
    "is_group": true,
    "chat_identifier": "chat123456789012345678",
    "chat_guid": "iMessage;+;chat123456789012345678",
    "group_name": "Weekend Camping",
    "message": "Sounds like a great plan! Looking forward to it.",
    "attachment_base64": "",
    "attachment_mime": "",
    "attachment_name": ""
  }
  ```

- **Field Definitions:**
  | Field | Type | Description |
  |---|---|---|
  | `sender` | string | Conversation routing identifier. For 1-on-1 chats, this is the remote sender handle (`+1...` or email). For group chats, this is the group ID (`chat...`), routing directly into the group conversation and ensuring replies target the group. |
  | `from` | string | The individual author/participant handle who sent the message within the chat. |
  | `participant` | string | Alias for `from`. |
  | `is_group` | boolean | `true` for group chats, `false` for direct 1-on-1 chats. |
  | `chat_identifier` | string | Canonical conversation identifier (`chat...` or phone/email). |
  | `chat_guid` | string | IMCore chat GUID (`iMessage;+;chat...` for groups, `iMessage;-;...` for 1-on-1). |
  | `group_name` | string | Display name of the group if set, or `""` if unnamed. |
  | `message` | string | Plain-text body. If the message contains only media, this will be an empty string `""` (`\uFFFC` placeholders are automatically stripped). |
  | `attachment_base64` | string | Base64-encoded binary string if media is present, or `""` if text-only. |
  | `attachment_mime` | string | MIME type (e.g. `image/jpeg`, `image/png`, `video/mp4`, `video/quicktime`). |
  | `attachment_name` | string | Original filename (e.g. `photo.jpg`, `IMG_1234.mov`). |
- **Expected Gateway Response:** HTTP `200 OK`.

---

### Outbound Send (Gateway → Relay)
Dispatches an outbound text message or media attachment to a contact.

- **Method:** `POST`
- **URL:** `http://<RELAY_HOST>:<PORT>/send` (or `/api/send`)
- **Accepted Request Keys (Supports standard and webhook-mirror keys):**
  - **Recipient:** `"recipient"`, `"to"`, `"sender"`, or `"destination"`.
  - **Chat GUID:** `"chat_guid"` or `"chat_identifier"` (optional alternative to recipient).
  - **Text Body:** `"text"`, `"body"`, `"message"`, or `"content"`.
  - **Attachment:** `"base64_data"`, `"attachment_base64"`, or `"data"`.
  - **MIME Type:** `"mime_type"` or `"attachment_mime"`.
  - **Filename:** `"filename"` or `"attachment_name"`.

#### Example 1: Send Text Message
```bash
curl -X POST http://<RELAY_HOST>:5569/send \
     -H "Authorization: Bearer <TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{
       "recipient": "+15551234567",
       "message": "Hello from gateway!"
     }'
```

#### Example 2: Send Image or Video with Caption
```bash
curl -X POST http://<RELAY_HOST>:5569/send \
     -H "Authorization: Bearer <TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{
       "recipient": "+15551234567",
       "message": "Check out this image!",
       "filename": "photo.jpg",
       "mime_type": "image/jpeg",
       "base64_data": "/9j/4AAQSkZJRgABAQEASABIAAD..."
     }'
```

#### Success Response (`200 OK`)
```json
{
  "status": "success",
  "message_guid": "E2B0D71A-8B22-4C22-BE9D-D4D70FF0A734",
  "recipient": "+15551234567",
  "chat_identifier": "+15551234567",
  "chat_guid": "iMessage;-;+15551234567",
  "timestamp": 1792174821.018,
  "transfer_guid": "7AD5E400-3170-4E38-9605-CD4E0410178B"
}
```

---

### Outbound Tapback Reactions (Gateway → Relay)
Sends a reaction to an existing message or removes a previously sent reaction.

- **Method:** `POST`
- **URL:** `http://<RELAY_HOST>:<PORT>/react` (or `/api/react`)
- **Payload Schema:**
  ```json
  {
    "original_message_guid": "E2B0D71A-8B22-4C22-BE9D-D4D70FF0A734",
    "tapback_type": "Love",
    "recipient": "+15551234567"
  }
  ```
- **Field Definitions:**
  | Field | Type | Required | Description |
  |---|---|---|---|
  | `original_message_guid` | string | **Yes** | GUID of target message (accepts raw UUID `"E2B0..."` or part GUID `"p:0/E2B0..."`). |
  | `tapback_type` | string / integer | **Yes** | Case-insensitive reaction name or integer code (see table below). |
  | `recipient` | string | Optional | Destination handle. If omitted, the daemon automatically looks up the recipient in `chat.db`. |
  | `remove` | boolean | Optional | Set to `true` to remove an existing reaction. |

#### Supported Tapback Types
| String Value (Case-Insensitive) | Add Code | Remove Code / String |
|---|---|---|
| `"Love"`, `"Heart"`, `"Loved"` | `2000` | `3000` / `"Remove Love"` |
| `"Like"`, `"ThumbsUp"`, `"Liked"` | `2001` | `3001` / `"Remove Like"` |
| `"Dislike"`, `"ThumbsDown"`, `"Disliked"` | `2002` | `3002` / `"Remove Dislike"` |
| `"Laugh"`, `"Haha"`, `"Laughed"` | `2003` | `3003` / `"Remove Laugh"` |
| `"Emphasize"`, `"Exclamation"`, `"!"` | `2004` | `3004` / `"Remove Emphasize"` |
| `"Question"`, `"QuestionMark"`, `"?"` | `2005` | `3005` / `"Remove Question"` |

#### Success Response (`200 OK`)
```json
{
  "status": "success",
  "message_guid": "00980C3A-6D40-4457-B304-52C58C462082",
  "original_message_guid": "E2B0D71A-8B22-4C22-BE9D-D4D70FF0A734",
  "associated_message_guid": "p:0/E2B0D71A-8B22-4C22-BE9D-D4D70FF0A734",
  "tapback_type": "Love",
  "tapback_code": 2000,
  "is_removal": 0,
  "recipient": "+15551234567",
  "backward_compatibility_text": "Loved “Hello from gateway!”",
  "timestamp": 1792174821.018
}
```

---

### Diagnostics & Management Endpoints

| Method | Endpoint | Description |
|---|---|---|
| `GET` / `POST` | `/status`, `/ping` | Returns daemon health, ping status, relay version (`v0.2.0-<commit>`), macOS version, active Apple ID / iMessage account status, listener IDs. |
| `GET` | `/chats` | Returns all known chat conversations, identifiers, and participants. |
| `GET` | `/accounts` | Lists registered accounts (iMessage and SMS) and connection state. |
| `GET` | `/help` | Lists available endpoints, service metadata, and relay version. |
| `POST`| `/retry-webhook` | Re-queries the newest incoming message from `chat.db` and dispatches it to the webhook. |
| `POST`| `/test-webhook` | Dispatches a synthetic test payload to verify gateway connectivity. |

#### Example: Daemon Status / Ping (`GET /status` or `GET /ping`)
```json
{
  "status": "online",
  "ping": "pong",
  "daemon_name": "crapple-relay-12",
  "version": "v0.2.0-b63e8029",
  "relay_version": "v0.2.0-b63e8029",
  "Relay version": "v0.2.0-b63e8029",
  "os_version": "macOS 12.7.6 (Monterey)",
  "commit": "b63e8029c5a60d6e8b95f9679a8e3b5851900a8f",
  "git_commit": "b63e8029c5a60d6e8b95f9679a8e3b5851900a8f",
  "message": "Relay is online. Relay version: v0.2.0-b63e8029 (macOS 12.7.6 (Monterey))",
  "incoming_observer_active": true,
  "daemon_connected": true,
  "listener_id": "crapple-relay-listener",
  "security": {
    "bound_host": "10.0.0.2",
    "incoming_port": 5569,
    "auth_type": "Bearer Token"
  },
  "outgoing_webhook": {
    "url": "http://10.0.0.1:5569/receive-imessage",
    "default_port": 5569,
    "auth_configured": 1
  },
  "imessage_account": {
    "login": "E:user@example.com",
    "service": "iMessage",
    "connected": true,
    "uniqueID": "35EE8FA3-77B6-4788-8A2E-EF97D27A775B"
  },
  "active_accounts_count": 2,
  "total_chats": 3,
  "accounts": [
    {
      "login": "E:user@example.com",
      "service": "iMessage",
      "connected": true,
      "uniqueID": "35EE8FA3-77B6-4788-8A2E-EF97D27A775B"
    },
    {
      "login": "E:",
      "service": "SMS",
      "connected": true,
      "uniqueID": "6F913F03-BCF0-4ABE-A9E4-B95C06B4D1A4"
    }
  ]
}
```

---

## 5. Networking Requirements & Topologies

The daemon is network-agnostic. It can bind to any IPv4 address using `--host <IP>` or the `RELAY_HOST` environment variable.

### Topology Options

#### Option A: Single-Node / Localhost (Same Mac)
If your gateway (e.g. Signal bridge, Matrix puppeting daemon, Python script, or Node.js server) runs on the same physical Mac as the relay:
- **Relay Configuration:**
  - Bind to loopback: `--host 127.0.0.1 --port 5569`
  - Webhook URL: `http://127.0.0.1:<GATEWAY_PORT>/receive-imessage`
- **Security:** Complete network isolation. No external ports are exposed.

#### Option B: Tailscale / WireGuard Private Mesh (Multi-Node)
If your gateway runs on a remote server or VPS:
- Install [Tailscale](https://tailscale.com) or WireGuard on both the Mac and the gateway server.
- The Mac receives an encrypted mesh IP (e.g. `100.x.y.z`).
- **Relay Configuration:**
  - Bind to Tailscale IP: `--host 100.x.y.z --port 5569`
  - Webhook URL: `http://100.a.b.c:<GATEWAY_PORT>/receive-imessage`
- **Security:** End-to-end encrypted wire traffic over NAT traversal; no public router port forwarding required.

#### Option C: Reverse Proxy with TLS (Nginx / Caddy / Cloudflare Tunnel)
If exposing across environments:
- Place the relay behind a local reverse proxy handling TLS termination and mutual TLS (mTLS).
- Keep the relay bound to `127.0.0.1`.

---

## 6. Daemon Deployment with launchd

On macOS, background daemons that require access to the user's Keychain and `chat.db` should be deployed as a **LaunchAgent** in `~/Library/LaunchAgents/`.

### LaunchAgent Configuration (`com.crapple.imessage-relay.plist`)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.crapple.imessage-relay</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/imessage-relay</string>
        <string>--port</string>
        <string>5569</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/usr/local/var/imessage-relay</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>RELAY_AUTH_TOKEN</key>
        <string>your-secure-token-here</string>
        <key>WEBHOOK_URL</key>
        <string>http://127.0.0.1:5569/receive-imessage</string>
        <key>WEBHOOK_AUTH_TOKEN</key>
        <string>your-secure-token-here</string>
    </dict>
</dict>
</plist>
```

### Installation Commands
```bash
# 1. Copy plist to LaunchAgents
cp com.crapple.imessage-relay.plist ~/Library/LaunchAgents/

# 2. Load and start service
launchctl load -w ~/Library/LaunchAgents/com.crapple.imessage-relay.plist

# 3. Verify running status
launchctl list | grep imessage-relay
```

### Unloading / Stopping
```bash
launchctl unload ~/Library/LaunchAgents/com.crapple.imessage-relay.plist
```

### Viewing Logs
The daemon logs directly to macOS Unified Logging and POSIX syslog. View logs in real-time without creating disk clutter:
```bash
/usr/bin/log stream --predicate 'process == "imessage-relay"'
```
Or filter specifically for daemon events:
```bash
/usr/bin/log stream --predicate 'subsystem == "com.crapple.imessage-relay"'
```
