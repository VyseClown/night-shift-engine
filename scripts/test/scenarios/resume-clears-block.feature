# QA procedure: --resume must clear a logic-blocked run (the malformed-signal
# cap) and drive it to completion — the operator-recovery path the block
# exists to make possible.
Scenario: --resume clears a logic block and the run completes
  Given a throwaway node project with a red test
  And the claude stub in mode "malformed"
  When the engine runs with the spec, expected to fail
  Then the live run status is "blocked"
  And the claude stub in mode "happy"
  When the engine runs again with the spec and --resume
  Then the archived run status is "complete"
  And the archived journal contains event "run_recovered" with ".payload.resumed_block==true"
  And the archived journal contains event "run_complete"
