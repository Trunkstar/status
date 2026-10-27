#!/usr/bin/env bash
# posts a teams adaptive card (same look as elastic-alerts) for every upptime incident
# issue opened or closed since $SINCE. upptime's own teams message is plain text, and its
# issues are made with github.token so an `on: issues` workflow would never fire.
#
# env: TEAMS_WEBHOOK_URL (the url is the credential: never printed), GH_TOKEN,
#      GITHUB_REPOSITORY, SINCE (iso time). TEST=1 sends one sample card.
set -euo pipefail

status_page="https://status.trunkstar.com"

# $1 banner style, $2 title, $3 subtitle, $4 big number, $5 its label, $6 site url,
# $7 detail line, $8 incident url
card() {
  jq -n --arg style "$1" --arg title "$2" --arg subtitle "$3" --arg number "$4" \
    --arg label "$5" --arg site "$6" --arg detail "$7" --arg incident "$8" \
    --arg status_page "$status_page" '{
    type: "message",
    attachments: [{
      contentType: "application/vnd.microsoft.card.adaptive",
      content: {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        type: "AdaptiveCard", version: "1.4", msteams: {width: "Full"},
        body: [
          {type: "Container", style: $style, bleed: true, items: [
            {type: "TextBlock", text: $title, size: "Large", weight: "Bolder", wrap: true},
            {type: "TextBlock", text: $subtitle, spacing: "None", isSubtle: true, wrap: true}
          ]},
          {type: "Container", separator: true, spacing: "Medium", items: [
            {type: "ColumnSet", columns: [
              {type: "Column", width: "auto", verticalContentAlignment: "Center", items: [
                {type: "TextBlock", text: $number, size: "ExtraLarge", weight: "Bolder",
                 color: (if $style == "good" then "Good" else "Attention" end), spacing: "None"},
                {type: "TextBlock", text: $label, size: "Small", isSubtle: true, spacing: "None"}
              ]},
              {type: "Column", width: "stretch", items: [
                {type: "TextBlock", text: "uptime check", size: "Small", isSubtle: true, spacing: "None"},
                {type: "TextBlock", text: $site, weight: "Bolder", spacing: "None", wrap: true},
                {type: "TextBlock", text: $detail, size: "Small", isSubtle: true, spacing: "None", wrap: true}
              ]}
            ]},
            {type: "ActionSet", spacing: "Small", actions: [
              {type: "Action.OpenUrl", title: "Open site", url: $site},
              {type: "Action.OpenUrl", title: "Incident", url: $incident},
              {type: "Action.OpenUrl", title: "Status page", url: $status_page}
            ]}
          ]}
        ]
      }
    }]
  }'
}

send() {
  if [ -z "${TEAMS_WEBHOOK_URL:-}" ]; then
    echo "$1"
    return
  fi
  # power automate answers 202, a legacy connector 200; never echo the url
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    --data "$1" "$TEAMS_WEBHOOK_URL" || true)
  echo "teams responded $code"
}

minutes_between() {
  echo $(( ($(date -d "$2" +%s) - $(date -d "$1" +%s)) / 60 ))
}

if [ "${TEST:-}" = "1" ]; then
  send "$(card attention "🔴 Test site is down" "test card · not a real incident" 503 "HTTP code" \
    "https://example.com" "response time 1234 ms" "https://github.com/$GITHUB_REPOSITORY/issues")"
  exit 0
fi

gh api "repos/$GITHUB_REPOSITORY/issues?labels=status&state=all&since=$SINCE&per_page=50" \
  --jq '.[] | @base64' | while read -r encoded; do
  issue=$(echo "$encoded" | base64 -d)
  field() { echo "$issue" | jq -r "$1"; }

  title=$(field .title)
  body=$(field .body)
  url=$(field .html_url)
  created=$(field .created_at)
  closed=$(field '.closed_at // empty')
  name=$(echo "$title" | sed -E 's/^(🛑|⚠️) //; s/ (is down|has degraded performance)$//')
  site=$(echo "$body" | sed -nE 's/.*\((https?:[^)]+)\) (was|experienced).*/\1/p' | head -1)
  http_code=$(echo "$body" | sed -nE 's/.*HTTP code: ([0-9]+).*/\1/p' | head -1)
  response_time=$(echo "$body" | sed -nE 's/.*Response time: ([0-9]+) ms.*/\1/p' | head -1)

  if [[ "$created" > "$SINCE" || "$created" == "$SINCE" ]]; then
    if [[ "$title" == ⚠️* ]]; then
      send "$(card warning "🟡 $name is slow" "degraded performance · $(date -d "$created" -u +%H:%M) UTC" \
        "${response_time:-?}" "ms" "$site" "HTTP ${http_code:-?}" "$url")"
    else
      send "$(card attention "🔴 $name is down" "since $(date -d "$created" -u +%H:%M) UTC" \
        "${http_code:-?}" "HTTP code" "$site" "response time ${response_time:-?} ms" "$url")"
    fi
  fi

  if [ -n "$closed" ] && [[ "$closed" > "$SINCE" || "$closed" == "$SINCE" ]]; then
    send "$(card good "🟢 $name is back up" "after $(minutes_between "$created" "$closed") min" \
      "$(minutes_between "$created" "$closed")" "min down" "$site" \
      "down since $(date -d "$created" -u '+%d %b %H:%M') UTC" "$url")"
  fi
done
