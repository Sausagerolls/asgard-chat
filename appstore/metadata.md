# App Store Connect listing: Asgard Chat (iOS / iPadOS)

Draft text for the App Store listing. Reviewer passwords are NOT stored here
(public repo); they are entered directly into App Store Connect.

## App information

- **Name:** Asgard Chat
- **Subtitle (30):** Private chat, your own server
- **Primary category:** Social Networking
- **Secondary category:** Productivity
- **Content rights:** Does not contain third-party content
- **Age rating:** answer "No" to everything except "Unrestricted Web Access: No" and
  "User-generated content / messaging between users: Yes". Expected result: 12+ / 13+.

## Version 1.0.0

**Promotional text (170):**
Your messages, your server. Asgard Chat is end-to-end encrypted messaging for families, friends and teams who run their own server.

**Description:**
Asgard Chat is a private messenger for people who want to own their conversations. It connects to an Asgard server you or someone you trust runs, at home or in the cloud, so your messages never live on a big company's servers.

END-TO-END ENCRYPTED
Every message, photo, voice note and file is encrypted on your device and can only be read by the people in the chat. Not even the server can read them.

EVERYTHING YOU EXPECT FROM A MESSENGER
• One-to-one chats, groups, channels and communities
• Photos, videos, files, voice notes and video notes
• Replies, reactions, edits, pins, polls and mentions
• Disappearing and view-once messages
• Folders, archive, search and starred messages
• Voice and video calls, plus drop-in voice rooms (on servers with calls enabled)

ALL YOUR DEVICES
Link your iPad, Mac or Android phone by scanning a QR code. Optional message history sync, protected by a recovery key only you hold, brings your chats to new devices.

PRIVATE BY DESIGN
• No phone number required, no ads, no tracking
• Invite-only servers: you decide who joins
• App lock with Face ID, and safety numbers to verify contacts
• Push notifications are relayed without message contents

YOUR SERVER, YOUR RULES
Asgard's server is open source and runs with one Docker command. Admins manage invites, users and storage from a web dashboard.

An invite or account on an Asgard server is required to sign in.

**Keywords (100):**
private,encrypted,messenger,self-hosted,e2ee,secure,chat,family,group,server,privacy,messaging

**Support URL:** https://github.com/Sausagerolls/asgard-chat/issues
**Marketing URL:** https://github.com/Sausagerolls/asgard-chat
**Privacy Policy URL:** https://github.com/Sausagerolls/asgard-chat/blob/main/PRIVACY.md
**Copyright:** 2026 Giant Mushroom Studio

## App Review information

- **Sign-in required:** Yes
- **Username:** reviewer1  (password in App Store Connect only)
- **Notes:**

  Asgard Chat is a messenger for self-hosted servers. We have set up a demo server for review.

  1. Open the app and choose Sign in.
  2. Server: https://chatdemo.giantmushroom.studio
  3. Username: reviewer1, password as provided in the sign-in fields.

  A second account (reviewer2, password: <reviewer2 password>) is available so you can message
  between two devices, or sign out and sign in as the other user. Both accounts already have a
  direct chat and a group ("App Review") with sample messages, which appear a few seconds after
  signing in.

  Voice/video calls need a media server (LiveKit) that the demo server does not run, so call
  buttons are hidden on this server. All messaging features work.

  Messages are end-to-end encrypted with standard algorithms (X25519, Ed25519,
  ChaCha20-Poly1305 via Apple CryptoKit).

## App Privacy (nutrition label)

Data is stored on the server the user signs in to, not by the developer. Suggested answers:
- **Data collection:** "No, we do not collect data from this app." The developer runs no
  servers that receive user data; the push relay only forwards an opaque wake-up and never
  receives message content or identifiers tied to identity.
  (If you prefer to be conservative: Contact info › Name / User ID, "App functionality", not
  linked to tracking.)
- **Tracking:** No.

## Export compliance

The app uses encryption (end-to-end messaging). Standard algorithms only, via CryptoKit.
App Store Connect will ask per build unless `ITSAppUsesNonExemptEncryption` is set in the
Info.plist; decide with the questionnaire (usually "Yes, uses encryption" + qualifies for
exemption under mass-market / standard algorithms in the EU/US self-classification).
