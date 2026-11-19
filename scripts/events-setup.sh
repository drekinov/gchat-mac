#!/usr/bin/env bash
# Provisions live notifications for one account on one Mac: a Pub/Sub topic per account and a pull
# subscription per Mac. Run it with gcloud signed in as an owner of the OAuth client's Cloud project.
set -euo pipefail

usage() {
    cat <<'EOF'
usage: events-setup.sh --project PROJECT --account N --email ADDRESS --device NAME
       events-setup.sh --project PROJECT --account N --remove

  --project   Cloud project that owns the Desktop OAuth client (billing must be enabled)
  --account   short number for the account, e.g. 1 (names the topic gchat-events-1)
  --email     the account's Google address; gets read and pull access on this Mac's subscription only
  --device    short name for this Mac, e.g. laptop (names the subscription gchat-events-1-laptop)
  --remove    deletes every pull subscription on the account's topic, then the topic

Prints the subscription path to paste into Settings › Accounts › Live notifications.
EOF
    exit 2
}

project="" account="" email="" device="" remove=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --project) project=$2; shift 2 ;;
        --account) account=$2; shift 2 ;;
        --email) email=$2; shift 2 ;;
        --device) device=$2; shift 2 ;;
        --remove) remove=1; shift ;;
        *) usage ;;
    esac
done
[[ -n $project && $account =~ ^[0-9]+$ ]] || usage

topic="gchat-events-$account"
topic_path="projects/$project/topics/$topic"
g() { gcloud --project "$project" --quiet "$@"; }

if [[ $remove == 1 ]]; then
    for sub in $(g pubsub topics list-subscriptions "$topic" --format='value(.)' 2>/dev/null); do
        g pubsub subscriptions delete "$sub"
    done
    g pubsub topics delete "$topic" || true
    echo "Removed $topic_path and its subscriptions. The Workspace subscription expires within 7 days."
    exit 0
fi

[[ $email == *@* && $device =~ ^[a-z][a-z0-9-]{0,20}$ ]] || usage
sub="$topic-$device"

g services enable pubsub.googleapis.com workspaceevents.googleapis.com chat.googleapis.com

if ! g pubsub topics describe "$topic" >/dev/null 2>&1; then
    g pubsub topics create "$topic"
fi
g pubsub topics add-iam-policy-binding "$topic" \
    --member=serviceAccount:chat-api-push@system.gserviceaccount.com --role=roles/pubsub.publisher >/dev/null

if ! g pubsub subscriptions describe "$sub" >/dev/null 2>&1; then
    g pubsub subscriptions create "$sub" --topic="$topic" \
        --ack-deadline=10 --message-retention-duration=10m --expiration-period=never
fi
for role in roles/pubsub.subscriber roles/pubsub.viewer; do
    g pubsub subscriptions add-iam-policy-binding "$sub" --member="user:$email" --role="$role" >/dev/null
done

cat <<EOF

Done. If you haven't yet, configure the Chat API (app name, avatar URL, description):
  https://console.cloud.google.com/apis/api/chat.googleapis.com/hangouts-chat?project=$project

Paste this into Settings › Accounts › Live notifications:
  projects/$project/subscriptions/$sub
EOF
