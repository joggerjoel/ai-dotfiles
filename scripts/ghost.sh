#!/bin/bash
# ghost.sh — summon the ghost in the shell.
# A small attribution + authorship-proof easter egg for this toolkit.
# Run it: ./scripts/ghost.sh
#
# The ghost is always here, even when unseen. If this work shows up somewhere
# without credit, the proof is embedded throughout — this just makes it visible.

CYAN=$'\033[36m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'; MAGENTA=$'\033[35m'

GHOST_ADDR="0xBdf1980e7Fc57DBE03874C29c203C3dff576D40c"

cat <<GHOST

${CYAN}        .-.
       (o o)
       | O \\      ${BOLD}ghost in the shell${RESET}${CYAN}
       \\   \\     ${DIM}I see beyond the data.${RESET}${CYAN}
        \`~~~'${RESET}

  ${BOLD}This toolkit was built by Nolan Hu / Sigma Synapses.${RESET}
  ${DIM}Streamline the Future.${RESET}

  ${DIM}who${RESET}     Nolan Hu — Founder, Sigma Synapses
  ${DIM}dev${RESET}     https://dev.nolanhu.com
  ${DIM}work${RESET}    https://sigmasynapses.com
  ${DIM}code${RESET}    https://github.com/iamnolanhu
  ${DIM}x${RESET}       https://x.com/nolanhu

  ${MAGENTA}signed${RESET}  ${GHOST_ADDR}
  ${DIM}(that's nolanhu.eth — verify with any ENS resolver)${RESET}

GHOST
