# Asgard push relay

Lets **anyone's** self-hosted Asgard server send notifications to the official
iPhone, iPad, Mac and Android apps, without ever holding Apple or Google push
keys. Only the relay has those keys; it runs on Google Cloud Run's free tier.

```
 phone ──(APNs/FCM token)──▶ relay ──▶ opaque handle ──▶ phone ──▶ its server
 server ──(signed {handle, encrypted payload})──▶ relay ──▶ Apple / Google ──▶ phone
```

## How it stays safe with servers you don't control

- **No database.** A server registers once (`POST /v1/servers`) and gets an id
  plus a secret derived from the relay master key. Apps turn their push token
  into a *handle* (`POST /v1/devices`): the token, platform and server id
  sealed with a key only the relay has (XChaCha20-Poly1305).
- **Servers never see device tokens**, only handles.
- **A handle only works for the server it was issued to.** A rogue server can
  reach only people who use that server.
- **Every push is signed** (HMAC-SHA256 over timestamp + body, 5-minute window).
- **Rate limits** per server (20/s sustained, burst 200, 50,000/day by
  default) and per IP for registrations. Abusive servers can be blocked with
  `RELAY_BLOCKED_SERVERS` (comma-separated server ids, from the logs).
- **Content stays private.** Payloads are the same end-to-end encrypted
  envelopes servers already send; the relay can't read them. It can see that
  a device got a notification, and when.

## Deploy (about 10 minutes, once)

You need a Google account with billing enabled (a card is required, but the
relay stays inside the free tier: Cloud Run gives 2 million requests a month,
and the service is capped at one instance so it can't scale into a bill).

1. Install the [gcloud CLI](https://cloud.google.com/sdk/docs/install) an d sign in: `gcloud auth login`.
2. Create a project at console.cloud.google.com and note its id.
3. Apple: developer.apple.com › Keys › **+** › *Apple Push Notifications service* → download the `.p8`.
4. Android: console.firebase.google.com › your project › Project settings ›
   Service accounts › *Generate new private key* (JSON). Use the same Firebase
   project whose `google-services.json` is built into the Android app.
5. Deploy:

```sh
PROJECT_ID=your-project \
APNS_KEY_FILE=~/Keys/AuthKey_ABC123DEF4.p8 APNS_KEY_ID=ABC123DEF4 APNS_TEAM_ID=J4UJD4Z33J \
FCM_CREDENTIALS_FILE=~/Keys/firebase-service-account.json \
DOMAIN=push.giantmushroom.studio \
BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX BUDGET=1GBP \
./relay/deploy.sh
```

`DOMAIN` maps your own subdomain (add the DNS records it prints).
`BILLING_ACCOUNT` (see `gcloud billing accounts list`) adds an email alert if
spending ever goes above £0.50 / £1.

Keep the key files out of this repository. They're uploaded to Google Secret
Manager and only the relay's own service account can read them.

## Servers

Asgard servers use `https://push.giantmushroom.studio` by default and register
themselves on first start. To use your own keys instead (only for apps you
build and sign yourself), set `ASGARD_PUSH_RELAY=off` and upload keys in the
web admin's Notifications page.

## Operating

- **Logs:** `gcloud run services logs read asgard-push --region europe-west1`
- **Block a server:** `gcloud run services update asgard-push --region europe-west1 --update-env-vars RELAY_BLOCKED_SERVERS=s1abc,s1def`
- **New Apple/Google key:** run `deploy.sh` again with the new file.
- **Master key:** never rotate it unless it leaks. If you do, servers register
  again automatically and apps re-register next time they open.
