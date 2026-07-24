# QA procedure: smoke proves the app BOOTS. A candidate that passes tests but
# fails smoke must not complete — this is the Release-bundle-break class.
Scenario: a candidate failing final smoke blocks instead of completing
  Given a throwaway node project with a red test
  And the spec declares a smoke command that fails only on the candidate
  And the claude stub in mode "happy"
  When the engine runs with the spec, expected to fail
  Then the live run status is "blocked"
  And the live state field ".block_reason" contains "smoke"
