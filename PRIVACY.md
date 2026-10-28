# Asgard Chat Privacy Policy

_Last updated: 28 October 2026_

Asgard Chat ("the app") is published by Giant Mushroom Studio ("we"). This policy explains what
happens to your information when you use the app on iPhone, iPad, Mac or Android.

## The short version

- Asgard Chat connects to an **Asgard server chosen by you**, run by you or by someone you trust
  (a family member, a club, your company). We do not run that server and cannot see its data.
- Messages, photos, files, voice notes and calls are **end-to-end encrypted**. Only the devices in
  a conversation can read them. The server, the server's operator and we cannot.
- We do not show ads, sell data, or track you across apps or websites. The app contains no
  analytics or advertising SDKs.

## Information stored on your Asgard server

To make the app work, the server you sign in to stores:

- your account: username, display name, optional bio and profile photo, and a hashed password;
- your devices' public encryption keys and device names;
- the conversations you belong to and their membership;
- encrypted messages and encrypted attachments until they are delivered, expire or are deleted
  (the server cannot decrypt them);
- basic metadata needed to deliver messages, such as who sent a message to which conversation and
  when.

This data is controlled by the operator of that server, not by us. Ask them how long they keep it,
or, if you run the server, see the documentation in this repository. You can delete messages and
sign out devices in the app, and a server admin can delete your account.

## Information stored on your device

Your chats are kept on your device so you can read them offline. Private encryption keys never
leave your device (they are kept in the iOS/macOS Keychain or the Android Keystore). If you turn
on message history sync, a copy of your message keys is stored on your server encrypted with a
recovery key that only you hold.

## Push notifications

If you allow notifications, your device's push token is registered with your Asgard server and,
through it, with our push relay (push.giantmushroom.studio). The relay only forwards a signal
telling your device to check for new messages. It never receives message content, sender names
or your username. Our hosting provider (Google Cloud) keeps standard request logs, such as IP
address and time, for up to 30 days to operate and secure the service. The relay uses Apple Push
Notification service and Firebase Cloud Messaging to deliver these signals; their handling of
tokens is covered by Apple's and Google's privacy policies.

A server operator can turn the relay off, in which case nothing is sent to us.

## Calls

Voice and video calls go through a media server (LiveKit) run alongside your Asgard server. Call
audio and video are end-to-end encrypted.

## Permissions

The app asks for access only when you use a feature that needs it: camera (photos, video, QR
codes, video calls), microphone (voice notes, calls), photo library (sending and saving media),
contacts (only if you choose to share a contact), location (only if you choose to share your
location), Face ID / Touch ID / biometrics (app lock), local network (servers on your home network),
Siri (shortcuts such as "Message …") and notifications.

## Children

The app is not directed at children under 13. Asgard servers are invite-only; server operators
decide who may join.

## Changes

We will update this page if this policy changes. The date at the top shows the latest version.

## Contact

Questions about this policy: open an issue at
https://github.com/Sausagerolls/asgard-chat/issues or contact Giant Mushroom Studio via
https://giantmushroom.studio.
