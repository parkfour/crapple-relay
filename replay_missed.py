#!/usr/bin/env python3
"""
Replay missed iMessages (ROWID >= 38) from chat.db to the remote gateway.
"""
import sqlite3
import os
import sys
import time
import urllib.request
import urllib.error
import json
import base64

WEBHOOK_URL = os.environ.get("WEBHOOK_URL", "http://10.0.0.1:5569/receive-imessage")
AUTH_TOKEN = os.environ.get("WEBHOOK_AUTH_TOKEN", "i-hate-crapple-secure-token-2026-69")
DB_PATH = os.path.expanduser("~/Library/Messages/chat.db")
SINCE_ROWID = int(sys.argv[1]) if len(sys.argv) > 1 else 38

def is_gateway_reachable(url):
    try:
        req = urllib.request.Request(url, method="OPTIONS")
        req.add_header("Authorization", f"Bearer {AUTH_TOKEN}")
        with urllib.request.urlopen(req, timeout=3) as resp:
            return resp.status in (200, 204, 401, 404, 405)
    except urllib.error.HTTPError as e:
        return e.code in (200, 204, 401, 404, 405)
    except Exception:
        return False

def get_messages(since_rowid):
    db = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    c = db.cursor()
    query = """
    SELECT m.ROWID, m.guid, m.text, h.id, m.is_from_me, m.date,
           att.filename, att.mime_type, att.transfer_name,
           c.chat_identifier, c.guid, c.style, c.display_name
    FROM message m
    LEFT JOIN handle h ON m.handle_id = h.ROWID
    LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
    LEFT JOIN chat c ON cmj.chat_id = c.ROWID
    LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id
    LEFT JOIN attachment att ON maj.attachment_id = att.ROWID
    WHERE m.is_from_me = 0 AND m.ROWID >= ?
    ORDER BY m.ROWID ASC;
    """
    rows = c.execute(query, (since_rowid,)).fetchall()
    messages = []
    for r in rows:
        row_id, guid, text, from_h, is_me, date_val, att_file, att_mime, att_name, chat_id, chat_guid, chat_style, disp_name = r
        is_group = (chat_style == 43) or (";+;" in (chat_guid or "")) or ((chat_id or "").startswith("chat"))
        sender = chat_id if is_group else (from_h or "")
        group_id = chat_id if is_group else ""
        clean_text = (text or "").replace("\ufffc", "").strip()
        
        # attachments
        att_b64 = ""
        final_mime = att_mime or ""
        final_name = att_name or ""
        if att_file:
            expanded = os.path.expanduser(att_file)
            if os.path.exists(expanded):
                try:
                    with open(expanded, "rb") as f:
                        att_b64 = base64.b64encode(f.read()).decode("ascii")
                    if not final_name:
                        final_name = os.path.basename(expanded)
                except Exception as e:
                    print(f"Warning: failed to read attachment {expanded}: {e}")

        # participants
        parts = [p[0] for p in c.execute("""
            SELECT DISTINCT h.id FROM chat_handle_join chj
            JOIN handle h ON chj.handle_id = h.ROWID
            JOIN chat c ON chj.chat_id = c.ROWID
            WHERE c.chat_identifier = ? OR c.guid = ?
            ORDER BY h.ROWID ASC
        """, (chat_id, chat_guid)).fetchall()]

        if not parts and from_h:
            parts = [from_h]

        payload = {
            "sender": sender,
            "group_chat_id": group_id,
            "correspondent": from_h or "",
            "from": from_h or "",
            "participant": from_h or "",
            "participants": parts,
            "is_group": is_group,
            "chat_identifier": chat_id or "",
            "chat_guid": chat_guid or "",
            "group_name": disp_name or "",
            "message": clean_text,
            "attachment_base64": att_b64,
            "attachment_mime": final_mime,
            "attachment_name": final_name
        }
        messages.append((row_id, guid, payload))
    db.close()
    return messages

def send_payload(payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(WEBHOOK_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if AUTH_TOKEN:
        req.add_header("Authorization", f"Bearer {AUTH_TOKEN}")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status, resp.read().decode("utf-8", errors="ignore")

def main():
    print(f"[+] Checking gateway reachability at {WEBHOOK_URL}...")
    if not is_gateway_reachable(WEBHOOK_URL):
        print(f"[!] Gateway at {WEBHOOK_URL} is currently unreachable.")
        sys.exit(1)
        
    messages = get_messages(SINCE_ROWID)
    print(f"[+] Found {len(messages)} incoming message(s) starting from ROWID {SINCE_ROWID}.")
    
    for row_id, guid, payload in messages:
        sender = payload.get("sender")
        corresp = payload.get("correspondent")
        text = payload.get("message")[:40]
        att = payload.get("attachment_name")
        print(f" -> Replaying ROWID {row_id} ({guid[:8]}...) from '{corresp}' in '{sender}': '{text}' (att: {att or 'none'})...")
        try:
            status, body = send_payload(payload)
            print(f"    [OK] HTTP {status}")
        except Exception as e:
            print(f"    [ERROR] Failed to dispatch ROWID {row_id}: {e}")
        time.sleep(0.5)

if __name__ == "__main__":
    main()
