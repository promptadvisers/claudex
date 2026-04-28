#!/usr/bin/env bash
# Claudex Personas
#
# Source this from stop-hook.sh:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/personas.sh"
#
# Provides:
#   claudex_persona_for_round <round>
#     Prints a focused reviewer-persona stanza for the given round number.
#     Round 1: skeptical senior engineer
#     Round 2: security and data-integrity reviewer
#     Round 3+: ops / SRE reviewer (deepens on later rounds)
#
#   claudex_persona_label_for_round <round>
#     Prints a one-line label for BLOCK headers (e.g. "Security review").

claudex_persona_label_for_round() {
  local r="${1:-1}"
  case "$r" in
    1) echo "Senior-engineer review" ;;
    2) echo "Security and data-integrity review" ;;
    *) echo "Ops and SRE review" ;;
  esac
}

claudex_persona_for_round() {
  local r="${1:-1}"
  case "$r" in
    1)
      cat <<'STANZA'
Persona: skeptical senior engineer doing the first pass.

Hunt for design flaws, broken assumptions, and ambiguous specs. Look for places where the plan glosses over hard parts, hand-waves edge cases, or solves the wrong problem. Flag anything that would obviously break under stress or that a reviewer in two weeks would call "we needed to think about this."
STANZA
      ;;
    2)
      cat <<'STANZA'
Persona: security and data-integrity reviewer doing the second pass.

Focus this round on: authentication and authorization gaps, input validation and injection, race conditions and concurrent-write hazards, partial-failure recovery and idempotency, secret handling, audit trails, and data-loss scenarios under crash or retry. Round 1 should have caught the obvious design issues; you are looking for the things that pass functional review but fail in production under adversarial or unlucky conditions.
STANZA
      ;;
    *)
      cat <<'STANZA'
Persona: operations and SRE reviewer doing a late-stage pass.

Focus this round on: rollback safety, observability and metrics, gradual rollout (feature flags, canaries), version skew between client and server, on-call ergonomics (runbooks, alerting), backwards compatibility, and capacity / blast-radius concerns. Earlier rounds should have hardened the design; you are checking that it can be deployed safely, monitored in flight, and reverted cleanly when something goes wrong. If this is a re-run of the ops persona on a later round, deepen the previous angles rather than going generic.
STANZA
      ;;
  esac
}
