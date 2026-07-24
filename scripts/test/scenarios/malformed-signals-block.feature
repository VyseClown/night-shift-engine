# QA procedure: five consecutive malformed/absent primary signals must hard-
# block the run rather than burn the whole turn budget on junk, and the
# blocked run must stay LIVE (never archived/compacted) so an operator can
# inspect or --resume it.
Scenario: five consecutive malformed signals block the run without archiving
  Given a throwaway node project with a red test
  And the claude stub in mode "malformed"
  When the engine runs with the spec, expected to fail
  Then the live run status is "blocked"
  And the live state field ".block_reason" contains "malformed"
  And the run is not archived
  And the live journal contains event "signal_rejected" with ".payload.consecutive==5"
  And the live journal contains event "run_blocked"
  And the live journal contains event "run_init"
