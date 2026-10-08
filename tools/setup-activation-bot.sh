#!/usr/bin/env bash
# ============================================================
# يربط بوت التفعيل (Snapchat+) بتيليغرام: setWebhook على دالة
# Vercel مع السر، ويتأكد بـ getWebhookInfo.
#
#   ACTIVATION_BOT_TOKEN=... ACTIVATION_WEBHOOK_SECRET=... \
#   SITE_URL=https://janeiro-store.com  bash tools/setup-activation-bot.sh
#
# نفس السر لازم يكون في متغيرات Vercel (ACTIVATION_WEBHOOK_SECRET).
# بلا سر تيليغرام ما يبعثش الترويسة، والدالة ترفض كل شي.
# ============================================================
set -euo pipefail

: "${ACTIVATION_BOT_TOKEN:?ACTIVATION_BOT_TOKEN (من @BotFather)}"
: "${ACTIVATION_WEBHOOK_SECRET:?ACTIVATION_WEBHOOK_SECRET (openssl rand -hex 32)}"
: "${SITE_URL:?SITE_URL (دومين Vercel، بلا / في الآخر)}"

API="https://api.telegram.org/bot${ACTIVATION_BOT_TOKEN}"
URL="${SITE_URL%/}/api/activation-bot"

curl -sS "$API/setWebhook" \
  --data-urlencode "url=$URL" \
  --data-urlencode "secret_token=$ACTIVATION_WEBHOOK_SECRET" \
  --data-urlencode 'allowed_updates=["message","callback_query"]' \
  --data-urlencode "drop_pending_updates=true"
echo
curl -sS "$API/getWebhookInfo"
echo
