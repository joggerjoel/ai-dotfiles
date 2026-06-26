#!/usr/bin/env bash
# Extract all open tabs from a browser into a structured TSV.
# Output format (pipe-delimited): TAB|<window>|<tab>|<title>|<url>
# Window markers: ===WINDOW <n> (<count> tabs)===
#
# Usage: ./extract-tabs.sh <browser>
#   browser: safari | chrome | arc | brave | edge
#
# If no arg, detects the frontmost supported browser.

set -uo pipefail

browser="${1:-}"

detect_frontmost() {
  osascript -e 'tell application "System Events" to name of first process whose frontmost is true' 2>/dev/null
}

if [[ -z "$browser" ]]; then
  front="$(detect_frontmost)"
  case "$front" in
    Safari) browser="safari" ;;
    "Google Chrome") browser="chrome" ;;
    Arc) browser="arc" ;;
    "Brave Browser") browser="brave" ;;
    "Microsoft Edge") browser="edge" ;;
    *)
      echo "ERROR: could not detect supported browser (frontmost: $front)" >&2
      echo "Pass one explicitly: safari | chrome | arc | brave | edge" >&2
      exit 1
      ;;
  esac
fi

case "$browser" in
  safari)
    osascript <<'AS'
tell application "Safari"
  set output to ""
  set wc to count of windows
  repeat with w from 1 to wc
    set theWindow to window w
    try
      set tc to count of tabs of theWindow
      set output to output & "===WINDOW " & w & " (" & tc & " tabs)===" & linefeed
      repeat with t from 1 to tc
        set theTab to tab t of theWindow
        set tabName to name of theTab
        set tabURL to URL of theTab
        set output to output & "TAB|" & w & "|" & t & "|" & tabName & "|" & tabURL & linefeed
      end repeat
    end try
  end repeat
  return output
end tell
AS
    ;;

  chrome)
    osascript <<'AS'
tell application "Google Chrome"
  set output to ""
  set wc to count of windows
  repeat with w from 1 to wc
    set theWindow to window w
    try
      set tc to count of tabs of theWindow
      set output to output & "===WINDOW " & w & " (" & tc & " tabs)===" & linefeed
      repeat with t from 1 to tc
        set theTab to tab t of theWindow
        set tabName to title of theTab
        set tabURL to URL of theTab
        set output to output & "TAB|" & w & "|" & t & "|" & tabName & "|" & tabURL & linefeed
      end repeat
    end try
  end repeat
  return output
end tell
AS
    ;;

  brave)
    osascript <<'AS'
tell application "Brave Browser"
  set output to ""
  set wc to count of windows
  repeat with w from 1 to wc
    set theWindow to window w
    try
      set tc to count of tabs of theWindow
      set output to output & "===WINDOW " & w & " (" & tc & " tabs)===" & linefeed
      repeat with t from 1 to tc
        set theTab to tab t of theWindow
        set tabName to title of theTab
        set tabURL to URL of theTab
        set output to output & "TAB|" & w & "|" & t & "|" & tabName & "|" & tabURL & linefeed
      end repeat
    end try
  end repeat
  return output
end tell
AS
    ;;

  edge)
    osascript <<'AS'
tell application "Microsoft Edge"
  set output to ""
  set wc to count of windows
  repeat with w from 1 to wc
    set theWindow to window w
    try
      set tc to count of tabs of theWindow
      set output to output & "===WINDOW " & w & " (" & tc & " tabs)===" & linefeed
      repeat with t from 1 to tc
        set theTab to tab t of theWindow
        set tabName to title of theTab
        set tabURL to URL of theTab
        set output to output & "TAB|" & w & "|" & t & "|" & tabName & "|" & tabURL & linefeed
      end repeat
    end try
  end repeat
  return output
end tell
AS
    ;;

  arc)
    # Arc's AppleScript dictionary differs: uses "tabs" with "URL" and "title"
    # but window/tab indexing follows the Chromium model.
    osascript <<'AS'
tell application "Arc"
  set output to ""
  set wc to count of windows
  repeat with w from 1 to wc
    set theWindow to window w
    try
      set tc to count of tabs of theWindow
      set output to output & "===WINDOW " & w & " (" & tc & " tabs)===" & linefeed
      repeat with t from 1 to tc
        set theTab to tab t of theWindow
        set tabName to title of theTab
        set tabURL to URL of theTab
        set output to output & "TAB|" & w & "|" & t & "|" & tabName & "|" & tabURL & linefeed
      end repeat
    end try
  end repeat
  return output
end tell
AS
    ;;

  *)
    echo "ERROR: unsupported browser: $browser" >&2
    exit 1
    ;;
esac
